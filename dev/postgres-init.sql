-- PostgreSQL initialization script for ZiCDC development
-- This script sets up the database, users, and test data for CDC testing

\echo 'Starting ZiCDC database initialization...'

-- Create a dedicated user for replication (optional, for production-like setup)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'zicdc_user') THEN
        CREATE ROLE zicdc_user WITH LOGIN PASSWORD 'zicdc_password' REPLICATION;
        RAISE NOTICE 'Created zicdc_user with replication privileges';
    ELSE
        RAISE NOTICE 'zicdc_user already exists';
    END IF;
END
$$;

-- Grant necessary permissions
GRANT CONNECT ON DATABASE zicdc_test TO zicdc_user;
GRANT USAGE ON SCHEMA public TO zicdc_user;
GRANT CREATE ON SCHEMA public TO zicdc_user;

-- Create sample tables for CDC testing
\echo 'Creating sample tables...';

CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    status VARCHAR(50) DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    price DECIMAL(10,2) NOT NULL,
    inventory_count INTEGER DEFAULT 0,
    category VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    total_amount DECIMAL(10,2) NOT NULL,
    order_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
    product_id INTEGER REFERENCES products(id) ON DELETE SET NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Table that should be excluded from CDC (for testing filtering)
CREATE TABLE IF NOT EXISTS system_logs (
    id SERIAL PRIMARY KEY,
    level VARCHAR(20) NOT NULL,
    message TEXT NOT NULL,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_orders_user_id ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product_id ON order_items(product_id);

-- Create function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Add triggers to automatically update updated_at columns
DROP TRIGGER IF EXISTS update_users_updated_at ON users;
CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_products_updated_at ON products;
CREATE TRIGGER update_products_updated_at
    BEFORE UPDATE ON products
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_orders_updated_at ON orders;
CREATE TRIGGER update_orders_updated_at
    BEFORE UPDATE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Create publication for logical replication
-- This is what ZiCDC will subscribe to for receiving change events
DROP PUBLICATION IF EXISTS zicdc_publication;
CREATE PUBLICATION zicdc_publication FOR ALL TABLES;

-- Alternative: Create publication for specific tables only (more selective)
-- CREATE PUBLICATION zicdc_publication FOR TABLE users, products, orders, order_items;

-- Grant permissions on tables to zicdc_user
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO zicdc_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO zicdc_user;

-- Insert sample data for testing
\echo 'Inserting sample data...';

INSERT INTO users (email, name, status) VALUES
    ('alice@example.com', 'Alice Johnson', 'active'),
    ('bob@example.com', 'Bob Smith', 'active'),
    ('charlie@example.com', 'Charlie Brown', 'inactive'),
    ('diana@example.com', 'Diana Prince', 'active')
ON CONFLICT (email) DO NOTHING;

INSERT INTO products (name, description, price, inventory_count, category) VALUES
    ('Laptop Pro', 'High-performance laptop for developers', 1299.99, 50, 'Electronics'),
    ('Wireless Mouse', 'Ergonomic wireless optical mouse', 29.99, 200, 'Accessories'),
    ('Mechanical Keyboard', 'RGB mechanical keyboard', 149.99, 75, 'Accessories'),
    ('4K Monitor', '27-inch 4K IPS monitor', 399.99, 30, 'Electronics'),
    ('USB-C Hub', 'Multi-port USB-C hub', 59.99, 100, 'Accessories')
ON CONFLICT DO NOTHING;

INSERT INTO orders (user_id, status, total_amount) VALUES
    (1, 'completed', 1329.98),
    (2, 'pending', 179.98),
    (3, 'processing', 459.98),
    (1, 'shipped', 89.98)
ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (1, 1, 1, 1299.99),  -- Alice: Laptop
    (1, 2, 1, 29.99),    -- Alice: Mouse
    (2, 3, 1, 149.99),   -- Bob: Keyboard
    (2, 2, 1, 29.99),    -- Bob: Mouse
    (3, 4, 1, 399.99),   -- Charlie: Monitor
    (3, 5, 1, 59.99),    -- Charlie: USB-C Hub
    (4, 5, 1, 59.99),    -- Alice: Another USB-C Hub
    (4, 2, 1, 29.99)     -- Alice: Another Mouse
ON CONFLICT DO NOTHING;

-- Insert some system logs (these should be excluded from CDC)
INSERT INTO system_logs (level, message, metadata) VALUES
    ('INFO', 'Database initialized', '{"component": "init_script"}'),
    ('INFO', 'Sample data inserted', '{"tables": ["users", "products", "orders", "order_items"]}')
ON CONFLICT DO NOTHING;

-- Display setup information
\echo '';
\echo '=== ZiCDC Database Setup Complete ===';
\echo 'Database: zicdc_test';
\echo 'Main user: postgres (password: password)';
\echo 'CDC user: zicdc_user (password: zicdc_password)';
\echo 'Publication: zicdc_publication';
\echo '';
\echo 'Sample data inserted:';
SELECT 'users' as table_name, count(*) as row_count FROM users
UNION ALL
SELECT 'products', count(*) FROM products
UNION ALL
SELECT 'orders', count(*) FROM orders
UNION ALL
SELECT 'order_items', count(*) FROM order_items;

\echo '';
\echo 'To test logical replication, you can:';
\echo '1. Create a replication slot: SELECT pg_create_logical_replication_slot(''zicdc_slot'', ''pgoutput'');';
\echo '2. Read changes: SELECT * FROM pg_logical_slot_get_changes(''zicdc_slot'', NULL, NULL);';
\echo '3. Make some changes: UPDATE users SET status = ''premium'' WHERE id = 1;';
\echo '4. Read changes again to see the CDC events';
\echo '';

-- Show current replication slots (should be empty initially)
\echo 'Current replication slots:';
SELECT slot_name, plugin, slot_type, database, active, confirmed_flush_lsn
FROM pg_replication_slots;

\echo '';
\echo 'ZiCDC database initialization completed successfully!';