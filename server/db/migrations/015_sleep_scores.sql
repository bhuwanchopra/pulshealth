-- Persist PulsHealth's derived Sleep Score once per user/night.
-- The score is derived from HealthKit sleep samples using the scoring formula
-- in web/lib/sleep.ts. It is deliberately separate from Apple's proprietary score.
CREATE TABLE IF NOT EXISTS sleep_scores (
  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  sleep_date date NOT NULL,
  score smallint NOT NULL CHECK (score BETWEEN 0 AND 100),
  duration_points numeric(4,1) NOT NULL,
  consistency_points numeric(4,1) NOT NULL,
  interruption_points numeric(4,1) NOT NULL,
  bedtime_deviation_minutes smallint,
  baseline_nights smallint NOT NULL DEFAULT 0,
  awake_minutes integer NOT NULL DEFAULT 0,
  awake_periods smallint NOT NULL DEFAULT 0,
  algorithm_version smallint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, sleep_date)
);

CREATE INDEX IF NOT EXISTS sleep_scores_user_date_idx
  ON sleep_scores (user_id, sleep_date DESC);
