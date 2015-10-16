provider "openstack" {

}

resource "openstack_compute_secgroup_v2" "hcf-container-host-secgroup" {
    name = "${var.cluster-prefix}-container-host"
    description = "HCF Container Hosts"
    rule {
        from_port = 1
        to_port = 65535
        ip_protocol = "tcp"
        self = true
    }
    rule {
        from_port = 1
        to_port = 65535
        ip_protocol = "udp"
        self = true
    }
    rule {
        from_port = 22
        to_port = 22
        ip_protocol = "tcp"
        cidr = "0.0.0.0/0"
    }
    rule {
        from_port = 80
        to_port = 80
        ip_protocol = "tcp"
        cidr = "0.0.0.0/0"
    }
    rule {
        from_port = 443
        to_port = 443
        ip_protocol = "tcp"
        cidr = "0.0.0.0/0"
    }
}

resource "openstack_networking_floatingip_v2" "hcf-core-host-fip" {
  pool = "${var.openstack_floating_ip_pool}"
}

resource "openstack_blockstorage_volume_v1" "hcf-core-vol" {
  name = "${var.cluster-prefix}-core-vol"
  description = "Helion Cloud Foundry Core"
  size = "${var.core_volume_size}"
  availability_zone = "${var.openstack_availability_zone}"
}

resource "openstack_compute_instance_v2" "hcf-core-host" {
    name = "${var.cluster-prefix}-core"
    flavor_id = "${var.openstack_flavor_id}"
    image_id = "${var.openstack_base_image_id}"
    key_pair = "${var.openstack_keypair}"
    security_groups = [ "default", "${openstack_compute_secgroup_v2.hcf-container-host-secgroup.id}" ]
    network = { uuid = "${var.openstack_network_id}" }
    availability_zone = "${var.openstack_availability_zone}"

	floating_ip = "${openstack_networking_floatingip_v2.hcf-core-host-fip.address}"

    volume = {
        volume_id = "${openstack_blockstorage_volume_v1.hcf-core-vol.id}"
    }

    connection {
        host = "${openstack_networking_floatingip_v2.hcf-core-host-fip.address}"
        user = "ubuntu"
        key_file = "${var.key_file}"
    }

    provisioner "remote-exec" {
        inline = [
        "mkdir /tmp/ca",
        "sudo mkdir -p /opt/hcf/bin",
        "sudo chown ubuntu:ubuntu /opt/hcf/bin"
        ]
    }

    # Install scripts and binaries
    provisioner "file" {
        source = "scripts/"
        destination = "/opt/hcf/bin/"
    }

    provisioner "remote-exec" {
      inline = [
      "sudo chmod ug+x /opt/hcf/bin/*",
      "echo 'export PATH=$PATH:/opt/hcf/bin' | sudo tee /etc/profile.d/hcf.sh"
      ]
    }

    provisioner "file" {
        source = "cert/"
        destination = "/tmp/ca/"
    }    

    provisioner "remote-exec" {
        inline = <<EOF
set -e
CERT_DIR=/home/ubuntu/ca

mv /tmp/ca $CERT_DIR
cd $CERT_DIR

bash generate_root.sh
bash generate_intermediate.sh

bash generate_host.sh ${var.cluster-prefix}-root "*.${openstack_networking_floatingip_v2.hcf-core-host-fip.address}.xip.io"

EOF
    }

    # format the blockstorage volume
    provisioner "remote-exec" {
        inline = <<EOF
set -e
DEVICE=$(http_proxy= curl -Ss --fail http://169.254.169.254/2009-04-04/meta-data/block-device-mapping/ebs0)
DEVICE1=$(http_proxy= curl -Ss --fail http://169.254.169.254/2009-04-04/meta-data/block-device-mapping/ebs0)1
echo Mounting at $DEVICE
sudo mkdir -p /data
sudo parted -s -- $DEVICE unit MB mklabel gpt
sudo parted -s -- $DEVICE unit MB mkpart primary 2048s -0
sudo mkfs.ext4 $DEVICE1
echo $DEVICE1 /data ext4 defaults 0 2 | sudo tee -a /etc/fstab
sudo mount /data
EOF
    }

    provisioner "remote-exec" {
        inline = <<EOF
set -e
sudo apt-get install -y wget
sudo apt-key adv --keyserver hkp://pgp.mit.edu:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
echo deb https://apt.dockerproject.org/repo ubuntu-trusty main | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get purge -y lxc-docker*
sudo apt-get install -y docker-engine=1.8.3-0~trusty
sudo usermod -aG docker ubuntu
# allow us to pull from the docker registry
# TODO: this needs to be removed when we publish to Docker Hub
echo DOCKER_OPTS=\"--insecure-registry ${var.registry_host} -H tcp://0.0.0.0:2375 -H unix:///var/run/docker.sock -s devicemapper -g /data/docker\" | sudo tee -a /etc/default/docker
# We have to reboot since this switches our kernel.        
sudo reboot && sleep 10
EOF
    }

    #
    # gato
    #
    provisioner "remote-exec" {
        inline = ["docker pull ${var.registry_host}/hcf/hcf-gato"]
    }

    #
    # HCF consul
    #

    # configure consul
    provisioner "remote-exec" {
        inline = [
        "sudo mkdir -p /opt/hcf/etc",
        "sudo mkdir -p /data/hcf-consul"
        ]
    }

    provisioner "file" {
        source = "config/consul.json"
        destination = "/tmp/consul.json"
    }

    # start the HCF consul server
    provisioner "remote-exec" {
        inline = [
        "sudo mv /tmp/consul.json /opt/hcf/etc/consul.json",
        "docker run -d -P --restart=always -p 8401:8401 -p 8501:8501 -p 8601:8601 -p 8310:8310 -p 8311:8311 -p 8312:8312 --name hcf-consul-server -v /opt/hcf/bin:/opt/hcf/bin -v /opt/hcf/etc:/opt/hcf/etc -v /data/hcf-consul:/opt/hcf/share/consul -t ${var.registry_host}/hcf/consul-server:latest -bootstrap -client=0.0.0.0 --config-file /opt/hcf/etc/consul.json"
        ]
    }

    provisioner "remote-exec" {
        inline = [
        "curl -L https://region-b.geo-1.objects.hpcloudsvc.com/v1/10990308817909/pelerinul/hcf.tar.gz -o /tmp/hcf-config-base.tgz",
        "bash /opt/hcf/bin/wait_for_consul.bash http://`/opt/hcf/bin/get_ip`:8501",
        "bash /opt/hcf/bin/consullin.bash http://`/opt/hcf/bin/get_ip`:8501 /tmp/hcf-config-base.tgz"
        ]
    }

    # Send script to set up consul-based services, health checks, and assign
    # monit ports (until we stop using docker --net host)
    provisioner "remote-exec" {
        inline = [
        "bash /opt/hcf/bin/service_registration.bash"
        ]
    }

    #
    # nats
    #

    # start the nats server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always -p 4222:4222 -p 6222:6222 -p 8222:8222 --name cf-nats -t ${var.registry_host}/hcf/cf-v${var.cf-release}-nats:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]
    }

    # start the CF consul server
    provisioner "remote-exec" {
        inline = <<EOF
set -e
sudo mkdir -p /data/cf-consul

curl -X PUT -d 'false' http://`/opt/hcf/bin/get_ip`:8501/v1/kv/hcf/user/consul/require_ssl
curl -X PUT -d '["${openstack_compute_instance_v2.hcf-core-host.access_ip_v4}"]' http://`/opt/hcf/bin/get_ip`:8501/v1/kv/hcf/user/consul/agent/servers/lan
curl -X PUT -d '[]' http://`/opt/hcf/bin/get_ip`:8501/v1/kv/hcf/user/consul/encrypt_keys

curl -X PUT -d '"server"' http://`/opt/hcf/bin/get_ip`:8501/v1/kv/hcf/role/consul/consul/agent/mode
EOF
    }

    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always -p 8301:8301 -p 8302:8302 -p 8400:8400 -p 8500:8500 -p 8600:8600 --name cf-consul -v /data/cf-consul:/var/vcap/store -t ${var.registry_host}/hcf/cf-v${var.cf-release}-consul:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]
    }

    #
    # etcd
    #

    # start the etcd server
    provisioner "remote-exec" {
        inline = [
        "sudo mkdir -p /data/cf-etcd"
        ]
    }

    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always -p 2379:2379 -p 2380:2380 --name cf-etcd -v /data/cf-etcd:/var/vcap/store -t ${var.registry_host}/hcf/cf-v${var.cf-release}-etcd:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]
    }

    #
    # postgresql
    #

    # start the postgresql server
    provisioner "remote-exec" {
        inline = [
        "sudo mkdir -p /data/cf-postgres"
        ]
    }

    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always -p 5432:5432 --name cf-postgres -v /data/cf-postgres:/var/vcap/store -t ${var.registry_host}/hcf/cf-v${var.cf-release}-postgres:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # stats
    #

    # start the stats server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-stats -t ${var.registry_host}/hcf/cf-v${var.cf-release}-stats:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # ha_proxy
    #

    # start the ha_proxy server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-ha_proxy -t ${var.registry_host}/hcf/cf-v${var.cf-release}-ha_proxy:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # uaa
    #

    # start the uaa server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-uaa -t ${var.registry_host}/hcf/cf-v${var.cf-release}-uaa:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # api
    #

    # start the api server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-api -t ${var.registry_host}/hcf/cf-v${var.cf-release}-api:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # clock_global
    #

    # start the clock_global server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-clock_global -t ${var.registry_host}/hcf/cf-v${var.cf-release}-clock_global:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # api_worker
    #

    # start the api_worker server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-api_worker -t ${var.registry_host}/hcf/cf-v${var.cf-release}-api_worker:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # hm9000
    #

    # start the hm9000 server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-hm9000 -t ${var.registry_host}/hcf/cf-v${var.cf-release}-hm9000:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # doppler
    #

    # start the doppler server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-doppler -t ${var.registry_host}/hcf/cf-v${var.cf-release}-doppler:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # loggregator
    #

    # start the loggregator server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-loggregator -t ${var.registry_host}/hcf/cf-v${var.cf-release}-loggregator:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # loggregator_trafficcontroller
    #

    # start the loggregator_trafficcontroller server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-loggregator_trafficcontroller -t ${var.registry_host}/hcf/cf-v${var.cf-release}-loggregator_trafficcontroller:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # router
    #

    # start the router server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always -p 80:80 -p 443:443 --name cf-router -t ${var.registry_host}/hcf/cf-v${var.cf-release}-router:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }

    #
    # runner
    #

    # start the runner server
    provisioner "remote-exec" {
        inline = [
        "docker run -d -P --restart=always --net=host --name cf-runner -t ${var.registry_host}/hcf/cf-v${var.cf-release}-runner:latest http://`/opt/hcf/bin/get_ip`:8501"
        ]        
    }
}
