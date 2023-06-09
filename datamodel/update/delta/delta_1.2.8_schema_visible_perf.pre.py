from pum.core.deltapy import DeltaPy
import os
import subprocess

class DropViews128(DeltaPy):

    def run(self):

        drop_sql = "{}../../ordinary_data/views/drop_views.sql".format(self.delta_dir)
        pg = self.pg_service

        print()
        self.write_message("Dropping views")

        # Compose command
        cmd = 'psql "service = {pg}" -f {drop_sql}'.format(pg=pg, drop_sql=drop_sql)
        self.write_message(cmd)

        # Execute command
        subprocess.check_output(cmd, shell=True)
        self.write_message("Dropping views: done")