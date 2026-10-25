-- Synthetic academic programs for the fictional Summit Ridge University.
-- Load with: psql -f db/seed/001_programs.sql   (safe to re-run)
INSERT INTO admissions.program (program_code, program_name, degree_level) VALUES
    ('CSCI-BS', 'Computer Science',            'BS'),
    ('GEOE-BS', 'Geological Engineering',      'BS'),
    ('MECH-BS', 'Mechanical Engineering',      'BS'),
    ('ENVS-BS', 'Environmental Science',       'BS'),
    ('DSCI-MS', 'Data Science',                'MS'),
    ('MATS-PHD', 'Materials Science',          'PHD')
ON CONFLICT (program_code) DO NOTHING;
