PROJECT_NAME ?= cdc
DEBEZIUM_COMPRESSION_TYPE ?= none
DEBEZIUM_OFFSET_FLUSH_INTERVAL_MS ?= 1000
COMPOSE ?= DEBEZIUM_COMPRESSION_TYPE=$(DEBEZIUM_COMPRESSION_TYPE) DEBEZIUM_OFFSET_FLUSH_INTERVAL_MS=$(DEBEZIUM_OFFSET_FLUSH_INTERVAL_MS) docker compose -p $(PROJECT_NAME)

INFRA_SERVICES := postgres kafka postgres-exporter kafka-exporter prometheus grafana cadvisor kafka-ui
DEBEZIUM_SERVICES := debezium
OUTBOXX_SERVICES := outboxx
ALL_CDC_SERVICES := debezium outboxx

DURATION ?= 120
BATCH_SIZE ?= 10000
INTERVAL ?= 0
ROW_BYTES ?= 128
UPDATE_RATIO ?= 0
DELETE_RATIO ?= 0
REPORT_INTERVAL ?= 5

.PHONY: infra load start-debezium start-outboxx start-all reset create-slots slots status topics offsets logs ps

infra:
	$(COMPOSE) up -d --remove-orphans $(INFRA_SERVICES)
	-$(COMPOSE) stop debezium outboxx
	-$(COMPOSE) rm -sf debezium outboxx connector-init
	$(MAKE) create-slots

load: infra
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
	-$(COMPOSE) rm -sf outboxx debezium connector-init
	$(COMPOSE) up -d --build $(DEBEZIUM_SERVICES)
	$(COMPOSE) run --rm connector-init

start-outboxx:
	$(COMPOSE) up -d --remove-orphans $(INFRA_SERVICES)
	$(MAKE) create-slots
	-$(COMPOSE) rm -sf debezium connector-init outboxx
	$(COMPOSE) up -d --build $(OUTBOXX_SERVICES)

start-all:
	$(COMPOSE) up -d --remove-orphans $(INFRA_SERVICES)
	$(MAKE) create-slots
	-$(COMPOSE) rm -sf debezium outboxx connector-init
	$(COMPOSE) up -d --build $(ALL_CDC_SERVICES)
	$(COMPOSE) run --rm connector-init

reset:
	$(COMPOSE) down -v --remove-orphans
	-docker volume rm $(PROJECT_NAME)_postgres-data $(PROJECT_NAME)_kafka-data $(PROJECT_NAME)_prometheus-data $(PROJECT_NAME)_grafana-data

create-slots:
	$(COMPOSE) exec -T postgres psql -U postgres -d bench -f /sql/create-slots.sql

slots:
	$(COMPOSE) exec -T postgres psql -U postgres -d bench -f /sql/slot-lag.sql

status:
	curl -fsS http://localhost:8083/connectors/debezium/status | jq .

topics:
	$(COMPOSE) exec kafka /kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list

offsets:
	-$(COMPOSE) exec kafka /kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:9092 --topic debezium.public.benchmark_records
	-$(COMPOSE) exec kafka /kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:9092 --topic outboxx.public.benchmark_records

logs:
	$(COMPOSE) logs -f postgres kafka debezium outboxx connector-init workload prometheus grafana

ps:
	$(COMPOSE) ps
