PROJECT_NAME ?= cdc
DEBEZIUM_COMPRESSION_TYPE ?= none
DEBEZIUM_OFFSET_FLUSH_INTERVAL_MS ?= 1000
LOAD_POSTGRES_PORT ?= 15432
LOAD_KAFKA_PORT ?= 19092
LOAD_KAFKA_CONTROLLER_PORT ?= 19093
COMPOSE ?= DEBEZIUM_COMPRESSION_TYPE=$(DEBEZIUM_COMPRESSION_TYPE) DEBEZIUM_OFFSET_FLUSH_INTERVAL_MS=$(DEBEZIUM_OFFSET_FLUSH_INTERVAL_MS) LOAD_POSTGRES_PORT=$(LOAD_POSTGRES_PORT) LOAD_KAFKA_PORT=$(LOAD_KAFKA_PORT) LOAD_KAFKA_CONTROLLER_PORT=$(LOAD_KAFKA_CONTROLLER_PORT) docker compose -p $(PROJECT_NAME)

INFRA_SERVICES := postgres kafka postgres-exporter kafka-exporter prometheus grafana cadvisor kafka-ui
DEBEZIUM_SERVICES := debezium
OUTBOXX_SERVICES := outboxx
PGSTREAM_SERVICES := pgstream
ALL_CDC_SERVICES := debezium outboxx pgstream

DURATION ?= 120
BATCH_SIZE ?= 10000
INTERVAL ?= 0
ROW_BYTES ?= 128
UPDATE_RATIO ?= 0
DELETE_RATIO ?= 0
REPORT_INTERVAL ?= 5

MINUTES ?= 60

.PHONY: infra infra-up load start-debezium start-outboxx start-pgstream start-all reset create-slots slots status topics offsets check-gaps results logs ps

# Bring infra up and ensure slots exist, leaving any running CDC readers alone.
infra-up:
	$(COMPOSE) up -d --remove-orphans $(INFRA_SERVICES)
	$(MAKE) create-slots

# Clean pre-load baseline: infra up, CDC readers stopped, slots ready.
infra: infra-up
	-$(COMPOSE) stop debezium outboxx pgstream
	-$(COMPOSE) rm -sf debezium outboxx pgstream connector-init pgstream-init

# Generating load does not touch running readers, so lag/throughput can be
# watched live. Use `make infra` first for the readers-down backlog scenario.
load: infra-up
	$(COMPOSE) run --build --rm workload \
		--duration $(DURATION) \
		--batch-size $(BATCH_SIZE) \
		--interval $(INTERVAL) \
		--row-bytes $(ROW_BYTES) \
		--update-ratio $(UPDATE_RATIO) \
		--delete-ratio $(DELETE_RATIO) \
		--report-interval $(REPORT_INTERVAL)

start-debezium:
	$(COMPOSE) up -d --remove-orphans $(INFRA_SERVICES)
	$(MAKE) create-slots
	-$(COMPOSE) rm -sf outboxx pgstream debezium connector-init
	$(COMPOSE) up -d --build $(DEBEZIUM_SERVICES)
	$(COMPOSE) run --rm connector-init

start-outboxx:
	$(COMPOSE) up -d --remove-orphans $(INFRA_SERVICES)
	$(MAKE) create-slots
	-$(COMPOSE) rm -sf debezium connector-init pgstream outboxx
	$(COMPOSE) up -d --build $(OUTBOXX_SERVICES)

# pgstream uses a prebuilt image, so no --build. create-slots already ran
# pgstream-init, so the wal2json slot and pgstream schema exist by now.
start-pgstream:
	$(COMPOSE) up -d --remove-orphans $(INFRA_SERVICES)
	$(MAKE) create-slots
	-$(COMPOSE) rm -sf debezium connector-init outboxx pgstream
	$(COMPOSE) up -d $(PGSTREAM_SERVICES)

start-all:
	$(COMPOSE) up -d --remove-orphans $(INFRA_SERVICES)
	$(MAKE) create-slots
	-$(COMPOSE) rm -sf debezium outboxx pgstream connector-init
	$(COMPOSE) up -d --build $(ALL_CDC_SERVICES)
	$(COMPOSE) run --rm connector-init

reset:
	$(COMPOSE) down -v --remove-orphans
	-docker volume rm $(PROJECT_NAME)_postgres-data $(PROJECT_NAME)_kafka-data $(PROJECT_NAME)_prometheus-data $(PROJECT_NAME)_grafana-data

create-slots:
	$(COMPOSE) exec -T postgres psql -U postgres -d bench -f /sql/create-slots.sql
	-$(COMPOSE) run --rm pgstream-init

slots:
	$(COMPOSE) exec -T postgres psql -U postgres -d bench -f /sql/slot-lag.sql

status:
	curl -fsS http://localhost:8083/connectors/debezium/status | jq .

topics:
	$(COMPOSE) exec kafka /kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list

offsets:
	-$(COMPOSE) exec kafka /kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:9092 --topic debezium.public.benchmark_records
	-$(COMPOSE) exec kafka /kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:9092 --topic outboxx.public.benchmark_records
	-$(COMPOSE) exec kafka /kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:9092 --topic pgstream.public.benchmark_records

# Check the outboxx topic lost no message: every assigned id must be present.
check-gaps:
	@COMPOSE="$(COMPOSE)" bash scripts/check-gaps.sh

results:
	@MINUTES=$(MINUTES) bash scripts/results.sh

logs:
	$(COMPOSE) logs -f postgres kafka debezium outboxx pgstream connector-init pgstream-init workload prometheus grafana

ps:
	$(COMPOSE) ps
