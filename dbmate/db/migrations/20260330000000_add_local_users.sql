-- migrate:up
CREATE TABLE local_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) NOT NULL UNIQUE,
    name TEXT NOT NULL DEFAULT '',
    password_hash TEXT,
    invite_token UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    invite_expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    activated_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    last_login TIMESTAMP WITH TIME ZONE
);

CREATE INDEX idx_local_users_email ON local_users(email);
CREATE INDEX idx_local_users_invite_token ON local_users(invite_token);

-- migrate:down
DROP TABLE IF EXISTS local_users;
