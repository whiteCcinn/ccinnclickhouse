-- Demo data for screenshots and integration tests (ClickHouse 22.8+). One statement per ';' line end.
DROP DATABASE IF EXISTS shop;
CREATE DATABASE shop ENGINE = Atomic COMMENT 'Demo shop';
CREATE TABLE shop.events
(
    event_date Date,
    event_time DateTime,
    user_id UInt64,
    country LowCardinality(String),
    event_type Enum8('view' = 1, 'cart' = 2, 'purchase' = 3),
    amount Decimal(12, 2),
    url String CODEC(ZSTD(3)),
    payload String TTL event_date + INTERVAL 30 DAY,
    tags Array(String),
    INDEX idx_url url TYPE bloom_filter GRANULARITY 4,
    INDEX idx_amount amount TYPE minmax GRANULARITY 1,
    PROJECTION by_country (SELECT country, count(), sum(amount) GROUP BY country)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_type, user_id, event_time)
SAMPLE BY user_id
TTL event_date + INTERVAL 5 YEAR
SETTINGS index_granularity = 8192, min_bytes_for_wide_part = 0
COMMENT 'Clickstream events';
INSERT INTO shop.events SELECT toDate('2026-01-01') + intDiv(number, 2000) AS event_date, toDateTime(event_date) + number % 86400, number % 5000, ['CN', 'MY', 'US', 'DE', 'JP', 'SG'][intHash32(number) % 6 + 1], ['view', 'cart', 'purchase'][intHash32(number + 7) % 3 + 1], (intHash32(number) % 10000) / 50 + toMonth(event_date) * 3, concat('https://shop.example.com/p/', toString(number % 997)), repeat('x', number % 50), ['a', 'b'] FROM numbers(0, 100000) SETTINGS max_threads = 2, max_insert_threads = 1;
INSERT INTO shop.events SELECT toDate('2026-01-01') + intDiv(number, 2000) AS event_date, toDateTime(event_date) + number % 86400, number % 5000, ['CN', 'MY', 'US', 'DE', 'JP', 'SG'][intHash32(number) % 6 + 1], ['view', 'cart', 'purchase'][intHash32(number + 7) % 3 + 1], (intHash32(number) % 10000) / 50 + toMonth(event_date) * 3, concat('https://shop.example.com/p/', toString(number % 997)), repeat('x', number % 50), ['a', 'b'] FROM numbers(100000, 100000) SETTINGS max_threads = 2, max_insert_threads = 1;
INSERT INTO shop.events SELECT toDate('2026-01-01') + intDiv(number, 2000) AS event_date, toDateTime(event_date) + number % 86400, number % 5000, ['CN', 'MY', 'US', 'DE', 'JP', 'SG'][intHash32(number) % 6 + 1], ['view', 'cart', 'purchase'][intHash32(number + 7) % 3 + 1], (intHash32(number) % 10000) / 50 + toMonth(event_date) * 3, concat('https://shop.example.com/p/', toString(number % 997)), repeat('x', number % 50), ['a', 'b'] FROM numbers(200000, 100000) SETTINGS max_threads = 2, max_insert_threads = 1;
INSERT INTO shop.events SELECT toDate('2026-01-01') + intDiv(number, 2000) AS event_date, toDateTime(event_date) + number % 86400, number % 5000, ['CN', 'MY', 'US', 'DE', 'JP', 'SG'][intHash32(number) % 6 + 1], ['view', 'cart', 'purchase'][intHash32(number + 7) % 3 + 1], (intHash32(number) % 10000) / 50 + toMonth(event_date) * 3, concat('https://shop.example.com/p/', toString(number % 997)), repeat('x', number % 50), ['a', 'b'] FROM numbers(300000, 100000) SETTINGS max_threads = 2, max_insert_threads = 1;
INSERT INTO shop.events SELECT toDate('2026-01-01') + intDiv(number, 2000) AS event_date, toDateTime(event_date) + number % 86400, number % 5000, ['CN', 'MY', 'US', 'DE', 'JP', 'SG'][intHash32(number) % 6 + 1], ['view', 'cart', 'purchase'][intHash32(number + 7) % 3 + 1], (intHash32(number) % 10000) / 50 + toMonth(event_date) * 3, concat('https://shop.example.com/p/', toString(number % 997)), repeat('x', number % 50), ['a', 'b'] FROM numbers(400000, 100000) SETTINGS max_threads = 2, max_insert_threads = 1;
INSERT INTO shop.events SELECT toDate('2026-01-01') + intDiv(number, 2000) AS event_date, toDateTime(event_date) + number % 86400, number % 5000, ['CN', 'MY', 'US', 'DE', 'JP', 'SG'][intHash32(number) % 6 + 1], ['view', 'cart', 'purchase'][intHash32(number + 7) % 3 + 1], (intHash32(number) % 10000) / 50 + toMonth(event_date) * 3, concat('https://shop.example.com/p/', toString(number % 997)), repeat('x', number % 50), ['a', 'b'] FROM numbers(500000, 100000) SETTINGS max_threads = 2, max_insert_threads = 1;
CREATE TABLE shop.orders_latest (order_id UInt64, user_id UInt64, status String, amount Decimal(12, 2), version UInt32, updated_at DateTime)
ENGINE = ReplacingMergeTree(version) ORDER BY order_id COMMENT 'Latest order state';
INSERT INTO shop.orders_latest SELECT number, number % 5000, ['new', 'paid', 'shipped'][number % 3 + 1], (number % 500) / 3, 1, toDateTime('2026-03-01 00:00:00') + number FROM numbers(50000);
INSERT INTO shop.orders_latest SELECT number, number % 5000, 'shipped', (number % 500) / 3, 2, toDateTime('2026-03-05 00:00:00') + number FROM numbers(20000);
CREATE TABLE shop.daily_revenue (day Date, country LowCardinality(String), orders UInt64, revenue Decimal(18, 2))
ENGINE = SummingMergeTree ORDER BY (day, country);
CREATE MATERIALIZED VIEW shop.daily_revenue_mv TO shop.daily_revenue AS
SELECT event_date AS day, country, count() AS orders, sum(amount) AS revenue FROM shop.events WHERE event_type = 'purchase' GROUP BY day, country;
INSERT INTO shop.daily_revenue SELECT event_date, country, count(), sum(amount) FROM shop.events WHERE event_type = 'purchase' GROUP BY event_date, country;
CREATE TABLE shop.user_uniques (day Date, users AggregateFunction(uniq, UInt64), amount_quantiles AggregateFunction(quantiles(0.5, 0.9), Decimal(12, 2)))
ENGINE = AggregatingMergeTree ORDER BY day;
INSERT INTO shop.user_uniques SELECT event_date, uniqState(user_id), quantilesState(0.5, 0.9)(amount) FROM shop.events GROUP BY event_date;
CREATE TABLE shop.sessions (user_id UInt64, started DateTime, duration UInt32, sign Int8) ENGINE = CollapsingMergeTree(sign) ORDER BY (user_id, started);
INSERT INTO shop.sessions SELECT number % 1000, toDateTime('2026-02-01 00:00:00') + number * 60, number % 600, 1 FROM numbers(10000);
CREATE TABLE shop.cart_versions (cart_id UInt64, items UInt16, sign Int8, version UInt32) ENGINE = VersionedCollapsingMergeTree(sign, version) ORDER BY cart_id;
INSERT INTO shop.cart_versions SELECT number, number % 7, 1, 1 FROM numbers(5000);
CREATE VIEW shop.top_countries AS SELECT country, count() AS events, sum(amount) AS revenue FROM shop.events GROUP BY country ORDER BY revenue DESC;
CREATE TABLE shop.countries (code String, name String, region String) ENGINE = MergeTree ORDER BY code;
INSERT INTO shop.countries VALUES ('CN', 'China', 'Asia'), ('MY', 'Malaysia', 'Asia'), ('US', 'United States', 'Americas'), ('DE', 'Germany', 'Europe'), ('JP', 'Japan', 'Asia'), ('SG', 'Singapore', 'Asia');
CREATE DICTIONARY shop.country_dict (code String, name String, region String) PRIMARY KEY code
SOURCE(CLICKHOUSE(USER 'ccinn' PASSWORD 'ccinn-pass' DB 'shop' TABLE 'countries')) LIFETIME(MIN 300 MAX 600) LAYOUT(COMPLEX_KEY_HASHED());
CREATE TABLE shop.inserts_buffer (ts DateTime, value Float64) ENGINE = Memory;
CREATE TABLE shop.audit_log (ts DateTime, message String) ENGINE = TinyLog;
CREATE TABLE shop.discard (ts DateTime) ENGINE = Null;
CREATE TABLE shop.remote_feed (id UInt64, name String) ENGINE = URL('http://127.0.0.1:1/feed.csv', CSV);
CREATE TABLE shop.tiny_parts (id UInt64, ts DateTime) ENGINE = MergeTree ORDER BY id SETTINGS parts_to_delay_insert = 20, parts_to_throw_insert = 60;
SYSTEM STOP MERGES shop.tiny_parts;
