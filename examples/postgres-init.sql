-- PostgreSQL initialization script for ZiCDC development
-- This script sets up sample tables and logical replication

-- Create sample tables for testing CDC
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    total_amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    price DECIMAL(10,2) NOT NULL,
    inventory_count INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES orders(id),
    product_id INTEGER REFERENCES products(id),
    quantity INTEGER NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Table that should be excluded from CDC
CREATE TABLE audit_logs (
    id SERIAL PRIMARY KEY,
    table_name VARCHAR(255) NOT NULL,
    operation VARCHAR(10) NOT NULL,
    old_values JSONB,
    new_values JSONB,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create publication for logical replication
-- This will be used by ZiCDC to stream changes
CREATE PUBLICATION zicdc_publication FOR ALL TABLES;

-- Alternative: Create publication for specific tables only
-- CREATE PUBLICATION zicdc_publication FOR TABLE users, orders, products, order_items;

-- Insert sample data
INSERT INTO users (email, name, password_hash) VALUES
    ('alice@example.com', 'Alice Smith', '$2a$12$dummy_hash_1'),
    ('bob@example.com', 'Bob Johnson', '$2a$12$dummy_hash_2'),
    ('charlie@example.com', 'Charlie Brown', '$2a$12$dummy_hash_3');

INSERT INTO products (name, description, price, inventory_count) VALUES
    ('Laptop', 'High-performance laptop', 1299.99, 50),
    ('Mouse', 'Wireless optical mouse', 29.99, 200),
    ('Keyboard', 'Mechanical keyboard', 149.99, 75),
    ('Monitor', '27-inch 4K monitor', 399.99, 30);

INSERT INTO orders (user_id, status, total_amount) VALUES
    (1, 'completed', 1329.98),
    (2, 'pending', 179.98),
    (3, 'processing', 429.98);

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (1, 1, 1, 1299.99),
    (1, 2, 1, 29.99),
    (2, 3, 1, 149.99),
    (2, 2, 1, 29.99),
    (3, 4, 1, 399.99),
    (3, 2, 1, 29.99);

-- Create functions for testing updates
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Add triggers to automatically update updated_at columns
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_orders_updated_at BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_products_updated_at BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Grant necessary permissions
-- Note: In production, create a dedicated user with minimal required permissions
ALTER USER postgres WITH REPLICATION;

-- Display setup completion message
DO $$
BEGIN
    RAISE NOTICE 'ZiCDC development database initialized successfully!';
    RAISE NOTICE 'Created tables: users, orders, products, order_items, audit_logs';
    RAISE NOTICE 'Created publication: zicdc_publication';
    RAISE NOTICE 'Sample data inserted for testing';
END $$;