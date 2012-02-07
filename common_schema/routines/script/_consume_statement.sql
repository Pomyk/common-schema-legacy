--
--
--

delimiter //

drop procedure if exists _consume_statement //

create procedure _consume_statement(
   in   id_from      int unsigned,
   in   id_to      int unsigned,
   in   expect_single tinyint unsigned,
   out  consumed_to_id int unsigned,
   in depth int unsigned,
   in should_execute_statement tinyint unsigned
)
comment 'Reads (possibly nested) statement'
language SQL
deterministic
modifies sql data
sql security invoker
main_body: begin
    declare first_token text;
    declare first_state text;
    declare statement_level int unsigned;
    declare id_end_statement int unsigned; 
    
    declare mysql_statement TEXT CHARSET utf8;
    declare expanded_variables TEXT CHARSET utf8;
    declare expanded_variables_array_id int unsigned;
    
    declare expression text charset utf8;
    declare expression_statement text charset utf8;
    declare expression_result tinyint unsigned;
    
    declare peek_match tinyint unsigned;
    declare matched_token text charset utf8;
    
    declare while_statement_id_from int unsigned;
    declare while_statement_id_to int unsigned;
    declare foreach_statement_id_from int unsigned;
    declare foreach_statement_id_to int unsigned;
    declare if_statement_id_from int unsigned;
    declare if_statement_id_to int unsigned;
    declare else_statement_id_from int unsigned;
    declare else_statement_id_to int unsigned;

    declare foreach_variables_statement text charset utf8;
    declare foreach_collection text charset utf8;
    declare foreach_variables_array_id int unsigned;
    
    declare reset_query text charset utf8;

    statement_loop: while id_from <= id_to do
      if @_common_schema_script_break_type IS NOT NULL then
         set consumed_to_id := id_to;
         leave statement_loop;
      end if;

      SELECT level, token, state FROM _sql_tokens WHERE id = id_from INTO statement_level, first_token, first_state;
      -- ~~~ select depth, id_from, id_to, statement_level, first_token;
      case
        when first_state in ('whitespace', 'single line comment', 'multi line comment') then begin
	        -- Ignore whitespace
	        set id_from := id_from + 1;
	        iterate statement_loop;
	      end;
        when first_state = 'left braces' then begin
	        -- Start new block
            SELECT MIN(id) FROM _sql_tokens WHERE id > id_from AND state = 'right braces' AND level = statement_level INTO id_end_statement;
  	        if id_end_statement IS NULL then
	          call _throw_script_error(id_from, 'Unmatched "{" brace');
	        end if;
	        call _consume_statement(id_from+1, id_end_statement-1, FALSE, @_common_schema_dummy, depth+1, should_execute_statement);
	        set consumed_to_id := id_end_statement;
          end;
        when first_state = 'alpha' AND first_token in (SELECT statement FROM _script_statements WHERE statement_type = 'sql') then begin
	        -- This is a SQL statement
	        call _validate_statement_end(id_from, id_to, id_end_statement);
            if should_execute_statement then
              -- Construct the original statement, send it for execution.
              SELECT GROUP_CONCAT(DISTINCT SUBSTRING(token, 2)) FROM _sql_tokens WHERE id BETWEEN id_from AND id_end_statement AND state = 'expanded query_script variable' INTO expanded_variables;
              if expanded_variables IS NULL then
                -- No expanded variables found. Read the query directly from tokens.
                SELECT GROUP_CONCAT(token ORDER BY id SEPARATOR '') FROM _sql_tokens WHERE id BETWEEN id_from AND id_end_statement INTO mysql_statement;
              else
                -- Expanded variables found.
                call _take_local_variables_snapshot(expanded_variables);
                SELECT GROUP_CONCAT(IF(_qs_variables.variable_name IS NOT NULL, _qs_variables.value_snapshot, token) ORDER BY id SEPARATOR '') FROM _sql_tokens LEFT JOIN _qs_variables ON(state = 'expanded query_script variable' AND SUBSTRING(token, 2) = _qs_variables.variable_name) WHERE id BETWEEN id_from AND id_end_statement INTO mysql_statement;
              end if;
              call exec_single(mysql_statement);
              set @query_script_rowcount := @common_schema_rowcount;
            end if;
  	        set consumed_to_id := id_end_statement;
          end;
        when first_state = 'alpha' AND first_token in (SELECT statement FROM _script_statements WHERE statement_type = 'script') then begin
	        call _validate_statement_end(id_from, id_to, id_end_statement);	        
	        call _consume_script_statement(id_from, id_to, id_from + 1, id_end_statement, depth, first_token, should_execute_statement);
  	        set consumed_to_id := id_end_statement;
          end;
        when first_state = 'alpha' AND first_token = 'while' then begin
	        call _consume_expression(id_from + 1, id_to, TRUE, consumed_to_id, expression, expression_statement);
	        set id_from := consumed_to_id + 1;
	        -- consume single statement (possible compound by {})
            set @_common_schema_script_loop_nesting_level := @_common_schema_script_loop_nesting_level + 1;
	        call _consume_statement(id_from, id_to, TRUE, consumed_to_id, depth+1, FALSE);
            set @_common_schema_script_loop_nesting_level := @_common_schema_script_loop_nesting_level - 1;
	        set while_statement_id_from := id_from;
	        set while_statement_id_to := consumed_to_id;
            if should_execute_statement then
              -- Simulate "while" loop:
              interpret_while_loop: while TRUE do
                -- Check for 'break'/'return';
                if @_common_schema_script_break_type IS NOT NULL then
                  if @_common_schema_script_break_type = 'break' then
                    set @_common_schema_script_break_type := NULL;
                  end if;
                  leave interpret_while_loop;
                end if;
                -- Evaluate 'while' expression:
                call _evaluate_expression(expression, expression_statement, expression_result);
                if NOT expression_result then
                  leave interpret_while_loop;
                end if;
                -- Expression holds true. We revisit 'while' block
                call _consume_statement(while_statement_id_from, while_statement_id_to, TRUE, @_common_schema_dummy, depth+1, TRUE);
              end while;
            end if;
	      end;
        when first_state = 'alpha' AND first_token = 'loop' then begin
	        -- consume single statement (possible compound by {})
	        set id_from := id_from + 1;
            set @_common_schema_script_loop_nesting_level := @_common_schema_script_loop_nesting_level + 1;
	        call _consume_statement(id_from, id_to, TRUE, consumed_to_id, depth+1, FALSE);
            set @_common_schema_script_loop_nesting_level := @_common_schema_script_loop_nesting_level - 1;
	        set while_statement_id_from := id_from;
	        set while_statement_id_to := consumed_to_id;
	        call _consume_if_exists(consumed_to_id + 1, id_to, consumed_to_id, 'while', NULL, peek_match, @_common_schema_dummy);
	        if peek_match then
	          call _consume_expression(consumed_to_id + 1, id_to, TRUE, consumed_to_id, expression, expression_statement);
	          set id_from := consumed_to_id + 1;
            else
              call _throw_script_error(id_from, CONCAT('Expcted "while" on loop-while expression'));
	        end if;
	        call _expect_statement_delimiter(consumed_to_id + 1, id_to, consumed_to_id);
            set id_from := consumed_to_id + 1;

            if should_execute_statement then
              interpret_while_loop: while TRUE do
                -- Check for 'break'/'return';
                if @_common_schema_script_break_type IS NOT NULL then
                  if @_common_schema_script_break_type = 'break' then
                    set @_common_schema_script_break_type := NULL;
                  end if;
                  leave interpret_while_loop;
                end if;
                -- Execute statement:
                call _consume_statement(while_statement_id_from, while_statement_id_to, TRUE, @_common_schema_dummy, depth+1, TRUE);
                -- Evaluate 'while' expression:
                call _evaluate_expression(expression, expression_statement, expression_result);
                if NOT expression_result then
                  leave interpret_while_loop;
                end if;
              end while;
            end if;
	      end;
        when first_state = 'alpha' AND first_token = 'foreach' then begin
	        call _consume_foreach_expression(id_from + 1, id_to, consumed_to_id, depth, foreach_collection, foreach_variables_array_id, should_execute_statement);

	        set id_from := consumed_to_id + 1;
	        -- consume single statement (possible compound by {})
            set @_common_schema_script_loop_nesting_level := @_common_schema_script_loop_nesting_level + 1;
	        call _consume_statement(id_from, id_to, TRUE, consumed_to_id, depth+1, FALSE);
            set @_common_schema_script_loop_nesting_level := @_common_schema_script_loop_nesting_level - 1;
	        set foreach_statement_id_from := id_from;
	        set foreach_statement_id_to := consumed_to_id;
            if should_execute_statement then
              call _foreach(foreach_collection, NULL, foreach_statement_id_from, foreach_statement_id_to, TRUE, @_common_schema_dummy, foreach_variables_array_id, depth+1, TRUE);
            end if;
	      end;
        when first_state = 'alpha' AND first_token = 'if' then begin
	        call _consume_expression(id_from + 1, id_to, TRUE, consumed_to_id, expression, expression_statement);
	        set id_from := consumed_to_id + 1;
	        -- consume single statement (possible compound by {})
	        call _consume_statement(id_from, id_to, TRUE, consumed_to_id, depth+1, FALSE);
	        set if_statement_id_from := id_from;
	        set if_statement_id_to := consumed_to_id;
	        -- Is there an 'else' clause?
	        set else_statement_id_from := NULL;
	        call _consume_if_exists(consumed_to_id + 1, id_to, consumed_to_id, 'else', NULL, peek_match, @_common_schema_dummy);
	        if peek_match then
	          set id_from := consumed_to_id + 1;
              call _consume_statement(id_from, id_to, TRUE, consumed_to_id, depth+1, FALSE);
	          set else_statement_id_from := id_from;
              set else_statement_id_to := consumed_to_id;
	        end if;
            if should_execute_statement then
              -- Simulate "if" condition:
              call _evaluate_expression(expression, expression_statement, expression_result);
              if expression_result then
                -- "if" condition holds!
                call _consume_statement(if_statement_id_from, if_statement_id_to, TRUE, @_common_schema_dummy, depth+1, TRUE);
              else
                -- If there's an "else" statement -- invoke it!
                if else_statement_id_from IS NOT NULL then
                  call _consume_statement(else_statement_id_from, else_statement_id_to, TRUE, @_common_schema_dummy, depth+1, TRUE);
                end if;
              end if;
            end if;
	      end;
        when first_state = 'alpha' AND first_token in ('break', 'return') then begin
	        call _expect_statement_delimiter(id_from + 1, id_to, consumed_to_id);
	        if should_execute_statement then
	          set @_common_schema_script_break_type := first_token;
	        end if;
	      end;
        when first_state = 'statement delimiter' then begin
            call _throw_script_error(id_from, CONCAT('Empty statement not allowed. Use {} instead'));
	      end;
        when first_state = 'start' then begin
            if expect_single then
              call _throw_script_error(id_from, CONCAT('Unexpected end of script. Expected statement'));
            end if;
	        set consumed_to_id := id_from;
	      end;
	    else begin 
		    call _throw_script_error(id_from, CONCAT('Unsupported token: "', first_token, '"'));
		  end;
      end case;
      if expect_single then
         leave statement_loop;
      end if;
      set id_from := consumed_to_id + 1;
    end while;
    set id_from := consumed_to_id + 1;

    -- End of scope
    -- Reset local variables: remove mapping to user-defined-variables; reset value snapshots if any.
    SELECT GROUP_CONCAT('SET ', mapped_user_defined_variable_name, ' := NULL ' SEPARATOR ';') FROM _qs_variables WHERE declaration_depth = depth INTO reset_query;
    call exec(reset_query);
    UPDATE _qs_variables SET value_snapshot = NULL WHERE declaration_depth = depth;
end;
//

delimiter ;