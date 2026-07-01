ARG DEBEZIUM_VERSION=2.7
FROM quay.io/debezium/connect:${DEBEZIUM_VERSION}

ARG JMX_AGENT_VERSION=0.20.0

ADD https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_AGENT_VERSION}/jmx_prometheus_javaagent-${JMX_AGENT_VERSION}.jar /kafka/etc/jmx_prometheus_javaagent.jar
COPY jmx-exporter.yml /kafka/etc/jmx-exporter.yml

USER root
RUN chmod 0644 /kafka/etc/jmx_prometheus_javaagent.jar /kafka/etc/jmx-exporter.yml
USER kafka
