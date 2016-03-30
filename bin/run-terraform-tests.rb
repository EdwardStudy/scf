#!/usr/bin/env ruby

require 'json'
require 'tempfile'

class CalledProcessError < RuntimeError ; end

def run_processs(*args, silent: false)
  puts args.map(&:to_s).join(' ') unless silent
  status = Process.wait2(Process.spawn(*args)).last
  return if status.success?
  raise CalledProcessError, "Failed to run #{args.join(' ')}: #{status.exitstatus}"
end

def setup_environment
  open('/environ', 'r') do |env_file|
    env_file.each_line("\0") do |line|
      line.chomp! "\0"
      name, value = line.split('=', 2)
      if ['DOCKER_USERNAME', 'DOCKER_PASSWORD', 'DOCKER_EMAIL'].include? name
        ENV[name] = value unless value.empty?
        next
      end
      ENV[name] = value if name.start_with?('OS_') || name.start_with?('HCF_')
    end
  end
end

class TerraformTester
  def top_src_dir
    @top_src_dir ||= File.dirname(File.dirname(File.absolute_path(__FILE__))) 
  end

  def overrides_path
    return @overrides_file.path unless @overrides_file.nil?
    @overrides_file = Tempfile.new(['overrides', '.tfvars'])
    at_exit { @overrides_file.close! }
    @overrides_file.path
  end

  def ensure_overrides_file
    open(overrides_path, 'w') do |file|
      # tf var name => [env name, default] ; default is optional
      ({
        openstack_keypair:           'OS_SSH_KEYPAIR',
        key_file:                    'OS_SSH_KEY_PATH',
        openstack_availability_zone: ['OS_AVAILABILITY_ZONE', 'nova'],
        openstack_network_id:        'OS_NETWORK_ID',
        openstack_network_name:      'OS_NETWORK_NAME',
        openstack_region:            'OS_REGION_NAME',
        docker_username:             'DOCKER_USERNAME',
        docker_password:             'DOCKER_PASSWORD',
        docker_email:                'DOCKER_EMAIL',
        hcf_version:                 ['HCF_VERSION', 'develop']
      }).each_pair do |var_name, env_info|
        if env_info.is_a? String
          file.puts %(#{var_name} = "#{ENV[env_info]}")
        else
          env_name, default = env_info
          if default.nil?
            file.puts %(#{var_name} = "#{ENV[env_name]}") unless (ENV[env_name] || '').empty?
          else
            file.puts %(#{var_name} = "#{ENV[env_name] || default}")
          end
        end
      end
    end
  end

  def setup
    return if @setup_complete

    ENV['DOCKER_EMAIL'] ||= 'nobody@example.invalid'

    Dir.chdir top_src_dir

    ensure_overrides_file
    at_exit { cleanup }
    run_processs '/usr/local/bin/terraform', 'apply', "-var-file=#{overrides_path}"

    puts "Waiting for roles to be ready...\n"
    stop_time = Time.now + 30 * 60
    %w{/ - \\ |}.cycle do |c|
      begin
        run_ssh 'opt/hcf/bin/hcf-status --silent', silent: true
      rescue CalledProcessError
        delta = (stop_time - Time.now).to_i
        if delta < 0
          puts "\rTimed out waiting for roles"
          raise
        end
        printf "\r%c Waiting for roles, %d:%02d remaining", c, delta / 60, delta % 60
        sleep 10
      else
        break
      end
    end

    puts "\rRoles are ready"
    @setup_complete = true
  end

  def cleanup
    begin
      run_processs '/usr/local/bin/terraform', 'destroy', '-force', "-var-file=#{overrides_path}"
    rescue CalledProcessError
      sleep 1
      retry
    end
    @setup_complete = false
  end

  def floating_ip
    return @floating_ip if @floating_ip
    open('terraform.tfstate', 'rb') do |f|
      data = JSON.load(f)
      @floating_ip = data['modules'].first['outputs']['floating_ip']
    end
  end

  def ssh_hosts_path
    return @ssh_hosts_file.path unless @ssh_hosts_file.nil?
    @ssh_hosts_file = Tempfile.new('ssh_known_hosts')
    @ssh_hosts_file.close
    at_exit { @ssh_hosts_file.delete }
    @ssh_hosts_file.path
  end

  def run_ssh(cmd, silent: false)
    run_processs('ssh', '-o', "UserKnownHostsFile=#{ssh_hosts_path}", '-o', 'StrictHostKeyChecking=no',
                 '-i', ENV['OS_SSH_KEY_PATH'], '-l', 'ubuntu', '-q', '-tt', floating_ip, '--',
                 cmd, silent: silent)
  end

  def smoke_test
    setup
    run_ssh 'opt/hcf/bin/run-role.sh opt/hcf/etc smoke-tests'
  end
end

def main
  setup_environment
  TerraformTester.new.smoke_test
end

main
