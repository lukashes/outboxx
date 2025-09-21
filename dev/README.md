# ZiCDC Development Environment

Этот dev environment настроен для тестирования PostgreSQL logical replication и разработки ZiCDC.

## Быстрый старт

### 1. Запуск PostgreSQL

```bash
# Запустить PostgreSQL с логической репликацией
docker-compose up -d

# Проверить статус
docker-compose ps

# Посмотреть логи
docker-compose logs -f postgres
```

### 2. Подключение к базе данных

```bash
# Подключиться как основной пользователь
psql -h localhost -U postgres -d zicdc_test

# Или подключиться как CDC пользователь
psql -h localhost -U zicdc_user -d zicdc_test
```

### 3. Тестирование логической репликации

После подключения к базе выполните:

```sql
-- 1. Создать replication slot для тестирования
SELECT pg_create_logical_replication_slot('test_slot', 'pgoutput');

-- 2. Проверить что слот создался
SELECT slot_name, plugin, slot_type, database, active
FROM pg_replication_slots;

-- 3. Сделать изменения в данных
UPDATE users SET status = 'premium' WHERE id = 1;
INSERT INTO products (name, price, inventory_count, category)
VALUES ('Test Product', 99.99, 10, 'Test');

-- 4. Прочитать события CDC
SELECT lsn, xid, data
FROM pg_logical_slot_get_changes('test_slot', NULL, NULL);

-- 5. Удалить тестовый слот (когда закончите)
SELECT pg_drop_replication_slot('test_slot');
```

## Структура данных

База содержит тестовые таблицы:

- **users** - пользователи (4 записи)
- **products** - товары (5 записей)
- **orders** - заказы (4 записи)
- **order_items** - позиции заказов (8 записей)
- **system_logs** - системные логи (исключается из CDC)

## Проверка конфигурации CDC

### Проверить настройки PostgreSQL:

```sql
-- Уровень WAL (должен быть 'logical')
SHOW wal_level;

-- Максимальное количество WAL senders
SHOW max_wal_senders;

-- Максимальное количество replication slots
SHOW max_replication_slots;

-- Публикации для репликации
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete
FROM pg_publication;

-- Таблицы в публикации
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'zicdc_publication';
```

### Мониторинг активности:

```sql
-- Активные подключения
SELECT pid, usename, application_name, client_addr, state, query
FROM pg_stat_activity
WHERE application_name LIKE '%replication%' OR backend_type = 'walsender';

-- Статистика репликации
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;

-- WAL статистика
SELECT * FROM pg_stat_wal;
```

## Тестовые сценарии для CDC

### Сценарий 1: Простые изменения

```sql
-- INSERT
INSERT INTO users (email, name) VALUES ('test@example.com', 'Test User');

-- UPDATE
UPDATE products SET price = price * 1.1 WHERE category = 'Electronics';

-- DELETE
DELETE FROM system_logs WHERE created_at < NOW() - INTERVAL '1 hour';
```

### Сценарий 2: Массовые изменения

```sql
-- Массовое обновление
UPDATE products SET inventory_count = inventory_count + 10;

-- Batch insert
INSERT INTO orders (user_id, status, total_amount)
SELECT
    (RANDOM() * 3 + 1)::INTEGER as user_id,
    CASE WHEN RANDOM() < 0.5 THEN 'pending' ELSE 'processing' END as status,
    (RANDOM() * 1000 + 50)::DECIMAL(10,2) as total_amount
FROM generate_series(1, 5);
```

### Сценарий 3: Транзакционные изменения

```sql
BEGIN;
    UPDATE users SET status = 'vip' WHERE id = 1;
    INSERT INTO orders (user_id, status, total_amount) VALUES (1, 'completed', 199.99);
    UPDATE products SET inventory_count = inventory_count - 1 WHERE id = 2;
COMMIT;
```

## Отладка и устранение проблем

### Проверить логи PostgreSQL:

```bash
docker-compose logs postgres | grep -i error
docker-compose logs postgres | grep -i replication
```

### Перезапустить среду:

```bash
# Перезапустить с сохранением данных
docker-compose restart

# Полная перезагрузка (удалит данные!)
docker-compose down -v
docker-compose up -d
```

### Подключиться к контейнеру:

```bash
docker-compose exec postgres bash
```

## Очистка

```bash
# Остановить и удалить контейнеры
docker-compose down

# Удалить данные (осторожно!)
docker-compose down -v
docker volume rm zicdc_postgres_data
```

## Следующие шаги

После успешного тестирования логической репликации можно:

1. Начать разработку WAL reader в ZiCDC
2. Реализовать подключение к replication slot
3. Парсить полученные CDC события
4. Интегрировать с Kafka producer

Логическая репликация готова к использованию!