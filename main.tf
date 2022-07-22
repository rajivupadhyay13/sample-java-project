provider "aws" {
  profile    = "default"
  region     = "us-east-1"
}

resource "aws_emr_cluster" "cluster" {
  name                   = "${var.name}"
  release_label          = "${var.release_label}"
  applications           = "${var.applications}"
  termination_protection = false
  log_uri                = "${var.log_uri}"
  service_role           = "${var.service_role}"

  step_concurrency_level = "${var.step_concurrency_level}"

  ec2_attributes {
    key_name                          = "${var.key_name}"
    subnet_id                         = "${var.subnet_id}"
    emr_managed_master_security_group = "${var.emr_managed_master_security_group}"
    emr_managed_slave_security_group  = "${var.emr_managed_slave_security_group}"
    instance_profile                  = "${var.instance_profile}"
  }

  master_instance_group {
    name               = "${var.master_instance_group_name}"
    instance_type      = "${var.master_instance_group_instance_type}"
    instance_count     = "${var.master_instance_group_instance_count}"
    bid_price          = "${var.master_instance_group_bid_price}"
    ebs_config {
      iops = "${var.master_instance_group_ebs_iops}"
      size = "${var.master_instance_group_ebs_size}"
      type = "${var.master_instance_group_ebs_type}"
      volumes_per_instance = "${var.master_instance_group_ebs_volumes_per_instance}"
    }
  }

  core_instance_group {

    name           = "${var.core_instance_group_name}"
    instance_type  = "${var.core_instance_group_instance_type}"
    instance_count = "${var.core_instance_group_instance_count}"
    bid_price      = "${var.core_instance_group_bid_price}"    #Do not use core instances as Spot Instance in Prod because terminating a core instance risks data loss.
    ebs_config {
      iops = "${var.core_instance_group_ebs_iops}"
      size = "${var.core_instance_group_ebs_size}"
      type = "${var.core_instance_group_ebs_type}"
      volumes_per_instance = "${var.core_instance_group_ebs_volumes_per_instance}"
    }
  }

  tags = {
    Name        = "${var.name}"
    Project     = "${var.project}"
    Environment = "${var.environment}"
  }

  bootstrap_action {
    path = "s3://elasticmapreduce/bootstrap-actions/run-if"
    name = "runif"
    args = ["instance.isMaster=true", "echo running on master node"]
  }

  configurations_json = <<EOF
  [
    {
      "Classification": "hadoop-env",
      "Configurations": [
        {
          "Classification": "export",
          "Properties": {
            "JAVA_HOME": "/usr/lib/jvm/java-1.8.0"
          }
        }
      ],
      "Properties": {}
    },
    {
      "Classification": "spark-env",
      "Configurations": [
        {
          "Classification": "export",
          "Properties": {
            "JAVA_HOME": "/usr/lib/jvm/java-1.8.0"
          }
        }
      ],
      "Properties": {}
    }
  ]
EOF

  step {
    action_on_failure = "TERMINATE_CLUSTER"
    name   = "Launch Spark Job"
    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["spark-submit","--class","org.example.KinesisConsumerApp","--master","yarn","s3://serverless-encryption-poc/spark-kinesis-delta.jar" , "KinesisStreaming", "kinesis-data-stream", "https://kinesis.us-east-1.amazonaws.com"]
    }
  }

}


resource "aws_emr_instance_group" "task_instance_group" {

  name           = "${var.task_instance_group_name}"
  cluster_id     = join("", aws_emr_cluster.cluster.*.id)
  instance_type  = "${var.task_instance_group_instance_type}"
  instance_count = "${var.task_instance_group_instance_count}"
  bid_price      = "${var.task_instance_group_bid_price}"    #Spot Instances are preferred  in Prod
  ebs_config {
    iops = "${var.task_instance_group_ebs_iops}"
    size = "${var.task_instance_group_ebs_size}"
    type = "${var.task_instance_group_ebs_type}"
    volumes_per_instance = "${var.task_instance_group_ebs_volumes_per_instance}"
  }
}

resource "aws_launch_configuration" "example-launchconfig" {
  name_prefix     = "example-launchconfig"
  image_id        = "ami-0cff7528ff583bf9a"
  instance_type   = "m4.xlarge"
  key_name        = "${var.key_name}"
}

resource "aws_autoscaling_group" "example-autoscaling" {
  name                      = "example-autoscaling"
  vpc_zone_identifier       = [ "${var.subnet_id}", "subnet-06fcd0a4af7130ee3" , "subnet-0e65a354a254e3da6"  ]
  launch_configuration      = aws_launch_configuration.example-launchconfig.name
  min_size                  = 1
  max_size                  = 2
  health_check_grace_period = 300
  health_check_type         = "EC2"
  force_delete              = true

  tag {
    key                 = "Name"
    value               = "ec2 instance"
    propagate_at_launch = true
  }
}

# scale up alarm

resource "aws_autoscaling_policy" "example-cpu-policy" {
  name                   = "example-cpu-policy"
  autoscaling_group_name = aws_autoscaling_group.example-autoscaling.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = "1"
  cooldown               = "300"
  policy_type            = "SimpleScaling"
}

resource "aws_cloudwatch_metric_alarm" "example-cpu-alarm" {
  alarm_name          = "example-cpu-alarm"
  alarm_description   = "example-cpu-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElasticMapReduce"
  period              = "120"
  statistic           = "Average"
  threshold           = "10"

  dimensions = {
    "AutoScalingGroupName" = aws_autoscaling_group.example-autoscaling.name
  }

  actions_enabled = true
  alarm_actions   = [aws_autoscaling_policy.example-cpu-policy.arn]
}

# scale down alarm
resource "aws_autoscaling_policy" "example-cpu-policy-scaledown" {
  name                   = "example-cpu-policy-scaledown"
  autoscaling_group_name = aws_autoscaling_group.example-autoscaling.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = "-1"
  cooldown               = "300"
  policy_type            = "SimpleScaling"
}

resource "aws_cloudwatch_metric_alarm" "example-cpu-alarm-scaledown" {
  alarm_name          = "example-cpu-alarm-scaledown"
  alarm_description   = "example-cpu-alarm-scaledown"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElasticMapReduce"
  period              = "120"
  statistic           = "Average"
  threshold           = "5"

  dimensions = {
    "AutoScalingGroupName" = aws_autoscaling_group.example-autoscaling.name
  }

  actions_enabled = true
  alarm_actions   = [aws_autoscaling_policy.example-cpu-policy-scaledown.arn]
}
