# OpenBot database install

The additive SQL snapshot installs only into absent application schemas and preserves other project data. Its version matches the migration applied to the connected Jevie Supabase project. The launcher checks the upstream migration journal on later starts. Do not reapply the fresh snapshot over an existing installation; use a new reviewed migration for upgrades.
