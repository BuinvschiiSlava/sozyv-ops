CREATE TABLE demo_message (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    author varchar(64) NOT NULL,
    body text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO demo_message (author, body) VALUES
    ('operator', 'Monitoring is online'),
    ('backup', 'Restore drill is ready');
