require 'right_aws'
require 'configliere/config_block'
#
EMR_CONFIG_DIR = '~/.wukong' unless defined?(EMR_CONFIG_DIR)
#
Settings.define :emr_credentials_file, :description => 'A .json file holding your AWS access credentials. See http://bit.ly/emr_credentials_file for format'
Settings.define :access_key,           :description => 'AWS Access key',        :env_var => 'AWS_ACCESS_KEY_ID'
Settings.define :secret_access_key,    :description => 'AWS Secret Access key', :env_var => 'AWS_SECRET_ACCESS_KEY'
Settings.define :emr_runner,           :description => 'Path to the elastic-mapreduce command (~ etc will be expanded)'
Settings.define :emr_root,             :description => 'S3 bucket and path to use as the base for Elastic MapReduce storage, organized by job name'
Settings.define :emr_data_root,        :description => 'Optional '
Settings.define :emr_bootstrap_script, :description => 'Bootstrap actions for Elastic Map Reduce machine provisioning', :default => EMR_CONFIG_DIR+'/emr_bootstrap.sh', :type => :filename, :finally => lambda{ Settings.emr_bootstrap_script = File.expand_path(Settings.emr_bootstrap_script) }
Settings.define :bootstrap_scripts, :description => 'More bootstrap scripts', :default => []
Settings.define :additional_files, :description => 'Additional files to copy to each machine', :default => []
Settings.define :emr_extra_args,       :description => 'kludge: allows you to stuff extra args into the elastic-mapreduce invocation', :type => Array, :wukong => true
Settings.define :alive,                :description => 'Whether to keep machine running after job invocation', :type => :boolean
#
Settings.define :key_pair_file,        :description => 'AWS Key pair file',                               :type => :filename
Settings.define :key_pair,             :description => "AWS Key pair name. If not specified, it's taken from key_pair_file's basename", :finally => lambda{ Settings.key_pair ||= File.basename(Settings.key_pair_file.to_s, '.pem') if Settings.key_pair_file }
Settings.define :instance_type,        :description => 'AWS instance type to use',                        :default => 'm1.small'
Settings.define :bid_price,        :description => 'Bid price in $ for slave instances'
Settings.define :ami_version,        :description => 'Version of the AMI that amazon uses for the EMR instances'
Settings.define :hadoop_version,        :description => 'Version of Hadoop on the AMIs'
Settings.define :master_instance_type, :description => 'Overrides the instance type for the master node', :finally => lambda{ Settings.master_instance_type ||= Settings.instance_type }
Settings.define :jobflow,              :description => "ID of an existing EMR job flow. Wukong will create a new job flow"
Settings.define :compression,              :description => "lzop to enable LZOP compression on output", :default => 'false'
# This happens upon require, which is after Settings.resolve! done in the
# initialize method of Script. Hence, the file settings override commandline
# settings, which is an odd behaviour. So we re-use command line arguments later.
Settings.read(File.expand_path(EMR_CONFIG_DIR+'/emr.yaml'))
Settings.use(:commandline)
Settings.resolve!

module Wukong
  #
  # EMR Options
  #
  module EmrCommand

    def execute_emr_workflow
      # Make all bootstrap scripts look the same for the rest of the
      # code
      Settings.bootstrap_scripts = Settings.bootstrap_scripts.map do |script|
        base_name = script
        rest = []
        if script.is_a? Array
          base_name = script[0]
          rest = script[1..-1]
        end
        base_name = File.expand_path(base_name) unless base_name.start_with? 's3://'
        res = [ base_name ] + rest
        res
      end
      copy_script_to_cloud
      execute_emr_runner
    end

    def copy_script_to_cloud
      Log.info "  Copying this script to the cloud."
      S3Util.store(this_script_filename, mapper_s3_uri)
      S3Util.store(this_script_filename, reducer_s3_uri)
      S3Util.store(File.expand_path(Settings.emr_bootstrap_script), bootstrap_s3_uri)

      Settings.bootstrap_scripts.each do |script|
        unless script[0].start_with? "s3://"
          S3Util.store(File.expand_path(script[0]), bootstrap_s3_script_uri(script[0]))
        end
      end
      if Settings.additional_files.size > 1
        # Create a tar archive - tar.gz created with tar czf is unreadable on
        # EMR boxes
        `tar cf #{job_name}.tar #{Settings.additional_files.join(" ")}`
        if Settings.additional_files.find { |f| (Settings[:map_command] || "").start_with? f }
          # Update map commands for the tar directory name
          Settings[:map_command] = "#{job_name}.tar/#{Settings[:map_command]}"
        end
        if Settings.additional_files.find { |f| (Settings[:reduce_command] || "").start_with? f }
          # Update map commands for the tar directory name
          Settings[:reduce_command] = "#{job_name}.tar/#{Settings[:reduce_command]}"
        end
        Settings.additional_files = [ "#{job_name}.tar" ]
      end
      Settings.additional_files.each do |file|
        unless file.start_with? "s3://"
          S3Util.store(File.expand_path(file), bootstrap_s3_script_uri(file))
        end
      end
    end

    def copy_jars_to_cloud
      S3Util.store(File.expand_path('/tmp/wukong-libs.jar'), wukong_libs_s3_uri)
      # "--cache-archive=#{wukong_libs_s3_uri}#vendor",
    end

    def hadoop_options_for_emr_runner
      [hadoop_jobconf_options, hadoop_other_args].flatten.compact.uniq.map do |hdp_opt|
        hdp_opt.split(' ').map {|part| "--arg '#{part}'"}
      end.flatten
    end

    def execute_emr_runner
      # fix_paths!
      command_args = []
      if Settings.jobflow
        command_args << Settings.dashed_flag_for(:jobflow)
      else
        command_args << "--create --name=#{job_name}"
        command_args << Settings.dashed_flag_for(:alive)
        # The new style of elastic-mapreduce cluster type flags
        command_args << "--instance-group=master"
        command_args << Settings.dashed_flags([:master_instance_type, :instance_type]).join(' ')
        command_args << "--instance-count=1"
        command_args << "--instance-group=core"
        command_args << Settings.dashed_flags([:slave_instance_type, :instance_type], [:num_instances, :instance_count]).join(' ')
        command_args << Settings.dashed_flags(:bid_price).join(' ') if Settings.bid_price
        command_args << Settings.dashed_flags(:ami_version).join(' ')
        command_args << Settings.dashed_flags(:hadoop_version).join(' ')
        command_args << Settings[:emr_extra_args] unless Settings[:emr_extra_args].blank?
        command_args << Settings.dashed_flags(:availability_zone, :key_pair, :key_pair_file).join(' ')
        command_args << "--bootstrap-action=#{bootstrap_s3_uri}"

        Settings[:bootstrap_scripts].each do |script|
          command_args << "--bootstrap-action=#{bootstrap_s3_script_uri(script[0])}"
          command_args << "--args=#{script[1..-1].join(',')}" if script.size > 1
        end


      end

      command_args << Settings.dashed_flags(:enable_debugging, :step_action, [:emr_runner_verbose, :verbose], [:emr_runner_debug, :debug]).join(' ')
      command_args += emr_credentials
      command_args += [
        "--log-uri=#{log_s3_uri}",
        "--stream",
        "--mapper=#{Settings[:map_command] || mapper_s3_uri} ",
        "--reducer=#{Settings[:reduce_command] || reducer_s3_uri} ",
        "--input=#{input_paths.join(",")} --output=#{output_path}",
      ]
      Settings[:additional_files].each do |file|
        cache_cmd = file.end_with?(".tar") ? "cache-archive" : "cache"
        command_args << "--#{cache_cmd}=#{bootstrap_s3_script_uri(file)}##{File.basename(file)}"
      end
      # eg to specify zero reducers:
      # Settings[:emr_extra_args] = "--arg '-D mapred.reduce.tasks=0'"
      command_args += ['--arg -jobconf --arg mapred.output.compress=true --arg -jobconf --arg mapred.output.compression.codec=com.hadoop.compression.lzo.LzopCodec'] if Settings[:compression] == 'lzop'
      command_args += Settings[:emr_extra_args] unless Settings[:emr_extra_args].blank?
      command_args += hadoop_options_for_emr_runner
      Log.info 'Follow along at http://localhost:9000/job'

      execute_command!( emr_runner_command, *command_args )
    end

    def emr_runner_command
      if Settings.emr_runner.nil?
        "elastic-mapreduce" # Not defined in YAML, trust the system PATH, as when gem is installed
      else
        Settings.emr_runner
      end
    end

    def emr_credentials
      command_args = []
      if Settings.emr_credentials_file
        command_args << "--credentials #{File.expand_path(Settings.emr_credentials_file)}"
      else
        command_args << %Q{--access-id #{Settings.access_key} --private-key #{Settings.secret_access_key} }
      end
      command_args
    end

    # A short name for this job
    def job_handle
      File.basename($0,'.rb')
    end

    # Produces an s3 URI within the Wukong emr sandbox from a set of path
    # segments
    #
    # @example
    #   Settings.emr_root = 's3://emr.yourmom.com/wukong'
    #   emr_s3_path('log', 'my_happy_job', 'run-97.log')
    #   # => "s3://emr.yourmom.com/wukong/log/my_happy_job/run-97.log"
    #
    def emr_s3_path *path_segs
      File.join(Settings.emr_root, path_segs.flatten.compact)
    end

    def mapper_s3_uri
      emr_s3_path(job_handle, 'code', job_handle+'-mapper.rb')
    end
    def reducer_s3_uri
      emr_s3_path(job_handle, 'code', job_handle+'-reducer.rb')
    end
    def log_s3_uri
      emr_s3_path(job_handle, 'log', 'emr_jobs')
    end
    def bootstrap_s3_uri
      emr_s3_path(job_handle, 'bin', "emr_bootstrap.sh")
    end
    def bootstrap_s3_dir
      emr_s3_path(job_handle, 'bin')
    end
    def bootstrap_s3_script_uri(script)
      if script.start_with? "s3://"
        script
      else
        [bootstrap_s3_dir, File.basename(script)].join('/')
      end
    end
    def wukong_libs_s3_uri
      emr_s3_path(job_handle, 'code', "wukong-libs.jar")
    end

    ABSOLUTE_URI = %r{^/|^\w+://}
    #
    # Walk through the input paths and the output path. Prepends
    # Settings.emr_data_root to any that does NOT look like
    # an absolute path ("/foo") or a URI ("s3://yourmom/data")
    #
    def fix_paths!
      return if Settings.emr_data_root.blank?
      unless input_paths.blank?
        @input_paths = input_paths.map{|path|   (path =~ ABSOLUTE_URI) ? path : File.join(Settings.emr_data_root, path) }
      end
      unless output_path.blank?
        @output_path = [output_path].map{|path| (path =~ ABSOLUTE_URI) ? path : File.join(Settings.emr_data_root, path) }
      end
    end

    #
    # Simple class to coordinate s3 operations
    #
    class S3Util
      # class methods
      class << self
        def s3
          @s3 ||= RightAws::S3Interface.new(
            Settings.access_key, Settings.secret_access_key,
            {:multi_thread => true, :logger => Log, :port => 80, :protocol => 'http' })
        end
        def bucket_and_path_from_uri uri
          uri =~ %r{^s3\w*://([\w\.\-]+)\W*(.*)} and return([$1, $2])
        end
        def store filename, uri
          dest_bucket, dest_key = bucket_and_path_from_uri(uri)
          Log.debug "    #{filename} => #{dest_bucket} / #{dest_key}"
          contents = File.read(filename)
          s3.store_object(:bucket => dest_bucket, :key => dest_key, :data => contents)
        end
      end
    end

  end
  Script.class_eval do
    include EmrCommand
  end
end
