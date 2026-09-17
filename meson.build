# contrib/pg_lolor/meson.build

pg_lolor_sources = files(
  'pg_lolor.c',
  'pg_lolor_fsstubs.c',
  'pg_lolor_inv_api.c',
  'pg_lolor_largeobject.c',
  'pg_lolor_migrate.c',
)

if host_system == 'windows'
  pg_lolor_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'pg_lolor',
    '--FILEDESC', 'pg_lolor - large objects stored in regular tables',])
endif

pg_lolor = shared_module('pg_lolor',
  pg_lolor_sources,
  kwargs: contrib_mod_args,
)
contrib_targets += pg_lolor

install_data(
  'pg_lolor.control',
  'pg_lolor--1.0.sql',
  kwargs: contrib_data_args,
)

tests += {
  'name': 'pg_lolor',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'regress': {
    'sql': [
      'pg_lolor',
    ],
  },
  'tap': {
    'tests': [
      't/001_lolor_basic.pl',
      't/002_pg_upgrade.pl',
      't/003_dump_restore.pl',
      't/004_streaming_replication.pl',
      't/005_logical_replication.pl',
      't/006_promote_standby.pl',
      't/007_file_privileges.pl',
      't/008_drop_paths.pl',
      't/009_migration.pl',
      't/010_migration_locking.pl',
    ],
  },
}
