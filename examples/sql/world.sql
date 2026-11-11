CREATE TABLE IF NOT EXISTS World (
    id integer PRIMARY KEY,
    randomnumber integer NOT NULL CHECK (randomnumber BETWEEN 1 AND 10000)
);
INSERT INTO World (id, randomnumber)
SELECT id, 1 + ((id * 7919) % 10000)
FROM generate_series(1, 10000) AS id
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS example_jobs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    world_id integer NOT NULL REFERENCES World(id),
    kind text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
