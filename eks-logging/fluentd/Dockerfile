FROM fluent/fluentd-kubernetes-daemonset:v1.16-debian-elasticsearch8-1

USER root

RUN gem install fluent-plugin-s3 --no-document

USER fluent
