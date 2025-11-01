-- Initialize load testing database

-- Simple load testing table with event_timestamp for real lag measurement
CREATE TABLE IF NOT EXISTS load_events (
    id SERIAL PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,
    event_timestamp TIMESTAMP NOT NULL,
    user_id INTEGER NOT NULL
);

-- Enable REPLICA IDENTITY FULL for complete CDC
ALTER TABLE load_events REPLICA IDENTITY FULL;

-- Create index for performance
CREATE INDEX idx_load_events_timestamp ON load_events(event_timestamp);

-- Create publication for CDC
CREATE PUBLICATION outboxx_load_pub FOR TABLE load_events;

-- SELECT pg_create_logical_replication_slot('load_slot', 'pgoutput');

-- Grant permissions
GRANT ALL PRIVILEGES ON TABLE load_events TO postgres;
GRANT ALL PRIVILEGES ON SEQUENCE load_events_id_seq TO postgres;
