# Postgres with wal2json, which pgstream needs (debezium and outboxx use the
# built-in pgoutput). Neither the official postgres image nor debezium/postgres
# ships wal2json, so install it from the pgdg apt repo the base image already has.
# Recipe follows pgstream's own build/docker/postgres-18 image, minus the
# anonymizer extension the benchmark does not use.
FROM postgres:18
RUN apt-get update \
	&& apt-get install -y postgresql-18-wal2json \
	&& rm -rf /var/lib/apt/lists/*
