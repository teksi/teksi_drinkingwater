/*
	qWat - QGIS Water Module

	SQL file :: function to create views/trigger/rules to join parent table with multiple inherited tables
*/

CREATE OR REPLACE FUNCTION qwat_sys.fn_inherited_table_view(_parent_table json, _children_tables json[], _destination_schema text) RETURNS void AS
$BODY$
	DECLARE
		_parent_field_array text[];
		_child_field_array text[];
		_parent_field_list text;
		_child_field_list text;
		_view_rootname text;
		_view_name text;
		_function_trigger text;
		_child_table json;
		_merge_view_rootname text;
		_merge_view_name text;
		_sql_cmd text;
		_merge_delete_cmd text;
		_count integer := 0;
	BEGIN
		-- get array of fields for parent table
		EXECUTE format(	$$ SELECT ARRAY( SELECT attname FROM pg_attribute WHERE attrelid = %1$L::regclass AND attnum > 0 ORDER BY attnum ASC ) $$, _parent_table->>'table_name') INTO _parent_field_array;
		_parent_field_array := array_remove(_parent_field_array, (_parent_table->>'pkey')::text ); -- remove pkey from field list

		-- create command of update rule for parent fiels
		SELECT array_to_string(f, ', ')
			FROM ( SELECT array_agg(f||' = NEW.'||f) AS f
			FROM unnest(_parent_field_array) AS f ) foo
			INTO _parent_field_list;

  		-- create view and triggers/rules for 1:1 joined view
  		FOREACH _child_table IN ARRAY _children_tables LOOP
			RAISE NOTICE 'edit view for %', _child_table->>'shortname';

			-- define view name
			_view_rootname := 'vw_'||(_parent_table->>'shortname')||'_'||(_child_table->>'shortname');
			_view_name := _destination_schema||'.'||_view_rootname;
			_function_trigger := _destination_schema||'.ft_'||(_parent_table->>'shortname')||'_'||(_child_table->>'shortname')||'_insert';

			-- get array of fields for child table
			EXECUTE format(	$$ SELECT ARRAY( SELECT attname FROM pg_attribute WHERE attrelid = %1$L::regclass AND attnum > 0 ORDER BY attnum ASC ) $$, _child_table->>'table_name') INTO _child_field_array;
			_child_field_array := array_remove(_child_field_array, (_child_table->>'pkey')::text); -- remove pkey from field list

			-- view
			EXECUTE format('
				CREATE OR REPLACE VIEW %1$s AS
					SELECT %2$s, %3$s
				FROM %4$s t2 INNER JOIN %5$s t1 ON t1.%6$I = t2.%7$I;'
				, _view_name --1
				, 't1.id, t1.' || array_to_string(_parent_field_array, ', t1.') --2
				,        't2.' || array_to_string(_child_field_array,  ', t2.') --3
				, (_child_table->>'table_name')::regclass --4
				, (_parent_table->>'table_name')::regclass --5
				, _parent_table->>'pkey' --7
				, _child_table->>'pkey' --8
			);

			-- insert trigger function
			RAISE NOTICE '  trigger function';
			EXECUTE format('
				CREATE OR REPLACE FUNCTION %1$s()
					RETURNS trigger AS
					$$
					BEGIN
						INSERT INTO %2$s ( %3$I, %4$s ) VALUES ( %5$s, %6$s ) RETURNING id INTO NEW.id;
						INSERT INTO %7$s ( %8$I, %9$s )VALUES ( NEW.%3$I, %10$s );
						RETURN NEW;
					END;
					$$
					LANGUAGE plpgsql;'
				, _function_trigger --1
				, (_parent_table->>'table_name')::regclass --2
				, (_parent_table->>'pkey')::text --3
				, array_to_string(_parent_field_array, ', ') --4
				, _parent_table->>'pkey_nextval' --5
				, 'NEW.'||array_to_string(_parent_field_array, ', NEW.') --6
				, (_child_table->>'table_name')::regclass --7
				, (_child_table->>'pkey')::text --8
				, array_to_string(_child_field_array, ', ') --9
				, 'NEW.'||array_to_string(_child_field_array, ', NEW.') --10
			);

			-- insert trigger
			RAISE NOTICE '  trigger';
			EXECUTE format('
				CREATE TRIGGER %1$I
					  INSTEAD OF INSERT
					  ON %2$s
					  FOR EACH ROW
					  EXECUTE PROCEDURE %3$s();',
				'tr_'||_view_rootname||'_insert', --1
				_view_name::regclass, --2
				_function_trigger::regproc --3
			);
			
			
			-- update rule
			RAISE NOTICE '  update rule';
			SELECT array_to_string(f, ', ') -- create command of update rule for parent fiels
				FROM ( SELECT array_agg(f||' = NEW.'||f) AS f
				FROM unnest(_child_field_array)     AS f ) foo
				INTO _child_field_list;
			EXECUTE format('
				CREATE OR REPLACE RULE %1$I AS ON UPDATE TO %2$s DO INSTEAD
				(
				UPDATE %3$s SET %4$s WHERE %5$I = OLD.%5$I;
				UPDATE %6$s SET %7$s WHERE %8$I = OLD.%8$I;
				)'
				, 'rl_'||_view_rootname||'_update' --1
				, _view_name::regclass --2
				, (_parent_table->>'table_name')::regclass --3
				, _parent_field_list --4
				, (_parent_table->>'pkey')::text --5
				, (_child_table->>'table_name')::regclass --6
				, _child_field_list --7
				, (_child_table->>'pkey')::text --8
			);

			-- delete rule
			RAISE NOTICE '  delete rule';
			EXECUTE format('
				CREATE OR REPLACE RULE %1$I AS ON DELETE TO %2$s DO INSTEAD
				(
				DELETE FROM %3$s WHERE %4$I = OLD.%4$I;
				DELETE FROM %5$s WHERE %6$I = OLD.%6$I;
				)'
				, 'rl_'||_view_rootname||'_delete' --1
				, _view_name::regclass --2
				, (_child_table->>'table_name')::regclass --3
				, (_child_table->>'pkey')::text --4
				, (_parent_table->>'table_name')::regclass --5
				, (_parent_table->>'pkey')::text --6
			);
		END LOOP;



		-- merge view (all children tables)
		_merge_view_rootname := 'vw_'||(_parent_table->>'shortname')||'_merge';
		_merge_view_name := _destination_schema||'.'||_merge_view_rootname;
		_sql_cmd := format('CREATE OR REPLACE VIEW %s AS SELECT CASE ', _merge_view_name); -- create field to determine inherited table
		_count := 0;
		FOREACH _child_table IN ARRAY _children_tables LOOP
			_count = _count + 1;

			_sql_cmd := _sql_cmd || format('
				WHEN t%1$s.id IS NOT NULL THEN %2$L::text ',
				_count,
				_child_table->>'shortname'
			);
		END LOOP;
		_sql_cmd := _sql_cmd || format(' ELSE ''unknown''::text END AS %1$s_type, %2$s ',
			_parent_table->>'shortname',
			't0.id, t0.' || array_to_string(_parent_field_array, ', t0.')
		);
		_count := 0;
		FOREACH _child_table IN ARRAY _children_tables LOOP
			_count = _count + 1;
			EXECUTE format(	$$ SELECT ARRAY( SELECT attname FROM pg_attribute WHERE attrelid = %1$L::regclass AND attnum > 0 ORDER BY attnum ASC ) $$, _child_table->>'table_name') INTO _child_field_array;
			_child_field_array := array_remove(_child_field_array, (_child_table->>'pkey')::text); -- remove pkey from field list
			_sql_cmd := _sql_cmd || ', t' || _count || '.' || array_to_string(_child_field_array, ', t'||_count||'.');
		END LOOP;
		_sql_cmd := _sql_cmd || format(' FROM %s t0', (_parent_table->>'table_name')::regclass);
		_count := 0;
		FOREACH _child_table IN ARRAY _children_tables LOOP
			_count = _count + 1;
			_sql_cmd := _sql_cmd || format('
				LEFT JOIN %1$s t%2$s ON t0.%3$I=t%2$s.%4$I '
				, (_child_table->>'table_name')::regclass --1 
				, _count --2
				, (_parent_table->>'pkey')::text --3
				, (_child_table->>'pkey')::text --4
			);
		END LOOP;
		EXECUTE( _sql_cmd );



		-- insert function trigger for merge view
		_sql_cmd := format('
			CREATE OR REPLACE FUNCTION %1$s() RETURNS TRIGGER AS $$
			BEGIN
				INSERT INTO %2$s ( %3$I, %4$s ) VALUES ( %5$s, %6$s ) RETURNING %3$I INTO NEW.%3$I;
				CASE'
			, _destination_schema||'.ft_'||_merge_view_rootname||'_insert' --1
			, (_parent_table->>'table_name')::regclass --2
			, (_parent_table->>'pkey')::text --3
			, array_to_string(_parent_field_array, ', ') --4
			, _parent_table->>'pkey_nextval' --5
			, 'NEW.'||array_to_string(_parent_field_array, ', NEW.') --6
		);
		FOREACH _child_table IN ARRAY _children_tables LOOP
			EXECUTE format(	$$ SELECT ARRAY( SELECT attname FROM pg_attribute WHERE attrelid = %1$L::regclass AND attnum > 0 ORDER BY attnum ASC ) $$, _child_table->>'table_name') INTO _child_field_array;
			_child_field_array := array_remove(_child_field_array, (_child_table->>'pkey')::text); -- remove pkey from field list
			_sql_cmd := _sql_cmd || format('
				WHEN NEW.%1$I = %2$L THEN INSERT INTO %3$s ( %4$I, %5$s )VALUES (NEW.%6$I, %7$s );'
				, (_parent_table->>'shortname') || '_type' --1
				, _child_table->>'shortname'::text --2
				, (_child_table->>'table_name')::regclass --3
				, (_child_table->>'pkey')::text --4
				, array_to_string(_child_field_array, ', ') --5
				, (_parent_table->>'pkey')::text --6
				, 'NEW.'||array_to_string(_child_field_array, ', NEW.') --7
			);
		END LOOP;
		_sql_cmd := _sql_cmd || '
			END CASE;
			RETURN NEW;
			END;
			$$
			LANGUAGE plpgsql;';
		EXECUTE( _sql_cmd );
		EXECUTE format('
			CREATE TRIGGER %1$I
				  INSTEAD OF INSERT
				  ON %2$s
				  FOR EACH ROW
				  EXECUTE PROCEDURE %3$s();',
			'tr_'||_merge_view_rootname||'_insert', --1
			_merge_view_name::regclass, --2
			(_destination_schema||'.ft_'||_merge_view_rootname||'_insert')::regproc --3
		);



		-- update function trigger for merge view
		_sql_cmd := format('
			CREATE OR REPLACE FUNCTION %1$s() RETURNS TRIGGER AS $$
			BEGIN
			UPDATE %2$s SET %3$s WHERE %4$I = OLD.%4$I;
			/* Allow change type */
			IF OLD.%5$I <> NEW.%5$I THEN CASE'
			, _destination_schema||'.ft_'||_merge_view_rootname||'_update' --1
			, (_parent_table->>'table_name')::regclass --2
			, _parent_field_list --3
			, (_parent_table->>'pkey')::text --4
			, (_parent_table->>'shortname') || '_type' --5
		);
		FOREACH _child_table IN ARRAY _children_tables LOOP
			_sql_cmd := _sql_cmd || format('
				WHEN OLD.%1$I = %2$L THEN DELETE FROM %3$s WHERE %4$I = OLD.%4$I;'
				, (_parent_table->>'shortname') || '_type' --1
				, _child_table->>'shortname'::text --2
				, (_child_table->>'table_name')::regclass --3
				, (_child_table->>'pkey')::text --3
			);
		END LOOP;
		_sql_cmd := _sql_cmd || '
			END CASE;
			CASE';
		FOREACH _child_table IN ARRAY _children_tables LOOP
			_sql_cmd := _sql_cmd || format('
				WHEN NEW.%1$I = %2$L THEN INSERT INTO %3$s (%4$I) VALUES (OLD.%5$I);'
				, (_parent_table->>'shortname') || '_type' --1
				, _child_table->>'shortname'::text --2
				, (_child_table->>'table_name')::regclass --3
				, (_child_table->>'pkey')::text --4
				, (_parent_table->>'pkey')::text --5
			);
		END LOOP;
		_sql_cmd := _sql_cmd || '
			END CASE;
			END IF;
			CASE ';
		FOREACH _child_table IN ARRAY _children_tables LOOP
			-- write list of fields for update command
			EXECUTE format(	$$ SELECT ARRAY( SELECT attname FROM pg_attribute WHERE attrelid = %1$L::regclass AND attnum > 0 ORDER BY attnum ASC ) $$, _child_table->>'table_name') INTO _child_field_array;
			_child_field_array := array_remove(_child_field_array, (_child_table->>'pkey')::text); -- remove pkey from field list
			SELECT array_to_string(f, ', ') -- create command of update rule for parent fiels
				FROM ( SELECT array_agg(f||' = NEW.'||f) AS f
				FROM unnest(_child_field_array)     AS f ) foo
				INTO _child_field_list;

			_sql_cmd := _sql_cmd || format('
				WHEN NEW.%1$I = %2$L THEN UPDATE %3$s SET %4$s WHERE %5$I = OLD.%5$I;'
				, (_parent_table->>'shortname') || '_type' --1
				, _child_table->>'shortname'::text --2
				, (_child_table->>'table_name')::regclass --3
				, _child_field_list --4
				, (_child_table->>'pkey')::text --5
				);
		END LOOP;
		_sql_cmd := _sql_cmd || '
			END CASE;
			RETURN NEW;
			END;
			$$
			LANGUAGE plpgsql;';
		EXECUTE( _sql_cmd );
		EXECUTE format('
			CREATE TRIGGER %1$I
				  INSTEAD OF UPDATE
				  ON %2$s
				  FOR EACH ROW
				  EXECUTE PROCEDURE %3$s();',
			'tr_'||_merge_view_rootname||'_update', --1
			_merge_view_name::regclass, --2
			(_destination_schema||'.ft_'||_merge_view_rootname||'_update')::regproc --3
		);
		
		

		-- delete function trigger for merge view
		_sql_cmd := format('
			CREATE OR REPLACE RULE %1$I AS ON DELETE TO %2$s DO INSTEAD	(',
			'rl_'||_merge_view_rootname||'_delete', --1
			_merge_view_name::regclass --2
		);
		FOREACH _child_table IN ARRAY _children_tables LOOP
			_sql_cmd := _sql_cmd || format('
				DELETE FROM %1$s WHERE %2$I = OLD.%2$I;
				)'
				, (_child_table->>'table_name')::regclass --1
				, (_child_table->>'pkey')::text --2
			);
		END LOOP;
		_sql_cmd := _sql_cmd || format('
			DELETE FROM %1$s WHERE %2$I = OLD.%2$I;)'
			, (_parent_table->>'table_name')::regclass --1
			, (_parent_table->>'pkey')::text --2
		);

	END;
$BODY$
LANGUAGE plpgsql;