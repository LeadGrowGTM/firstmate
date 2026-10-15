# shellcheck shell=bash
# Per-home task-type catalog.
# Usage: . bin/fm-task-type-lib.sh
#
# docs/configuration.md "Task types" owns the file format.
# This file owns the refusal lines, the --list-types lines, and the brief
# section bin/fm-brief.sh renders for --type.
#
# fm_task_type_list <config-dir>
#   Prints "<name>: <use>" in file order.
#   An absent config/task-types.json prints nothing and returns 0.
#   An unreadable or malformed file prints one error line and returns 1.
# fm_task_type_render <config-dir> <name> <project>
#   On success sets FM_TASK_TYPE_SECTION and FM_TASK_TYPE_PROFILE (empty when
#   the type names neither model nor effort) and returns 0.
#   On failure prints one error line, clears both variables, and returns 1.
#   An absent file is a failure here: --type was asked to read a catalog.

# shellcheck disable=SC2034 # Consumed by fm_task_type_read below.
IFS= read -r -d '' FM_TASK_TYPE_LOAD_FILTER <<'JQ' || true
def one_line:
  if type != "string" then false
  elif test("[\n\r\t]") then false
  elif test("^[[:space:]]*$") then false
  else true end;

def err(m): {ok: false, error: m};

def pointers(where; key):
  if .[key] == null then {ok: true, items: []}
  elif (.[key] | type) != "array" then
    err("malformed config/task-types.json - \(where) \(key) must be an array of names or repo-relative paths")
  else
    reduce (.[key] | to_entries[]) as $e ({ok: true, items: []};
      if (.ok | not) then .
      elif ($e.value | one_line | not) then
        err("malformed config/task-types.json - \(where) \(key) entries must be one-line names or repo-relative paths")
      elif ($e.value | startswith("/")) or ($e.value | startswith("~")) then
        err("malformed config/task-types.json - \(where) \(key) must be names or repo-relative paths")
      else .items += [$e.value]
      end)
  end;

def field_err(where; key; detail):
  err("malformed config/task-types.json - \(where) \(key) \(detail)");

def take_required(where; key):
  if (.[key] | one_line) then {ok: true, value: .[key]}
  else field_err(where; key; "must be one line")
  end;

def take_optional_line(where; key):
  if .[key] == null then {ok: true, value: ""}
  elif (.[key] | one_line) then {ok: true, value: .[key]}
  else field_err(where; key; "must be one line")
  end;

def take_model(where):
  if .model == null then {ok: true, value: null}
  elif (.model | type) != "string" then field_err(where; "model"; "must be one token")
  elif (.model | test("[[:space:]=]")) or .model == "" then field_err(where; "model"; "must be one token")
  else {ok: true, value: .model}
  end;

def take_effort(where):
  .effort as $effort
  | if $effort == null then {ok: true, value: null}
    elif ($effort | type) == "string" and (["low", "medium", "high", "xhigh", "max", "ultra"] | index($effort)) != null then {ok: true, value: $effort}
    else field_err(where; "effort"; "must be low, medium, high, xhigh, max, or ultra")
    end;

def take_projects(where):
  if .projects == null then {ok: true, value: null}
  elif (.projects | type) != "array" or (.projects | length) == 0 then
    field_err(where; "projects"; "must list at least one project or be omitted")
  else
    reduce (.projects | to_entries[]) as $e ({ok: true, value: []};
      if (.ok | not) then .
      elif ($e.value | one_line | not) then field_err(where; "projects"; "entries must be one line")
      else .value += [$e.value]
      end)
  end;

def allowed: ["name", "use", "skills", "agents", "tools", "check", "hand_back", "model", "effort", "touch", "projects"];

def one_type($i):
  if type != "object" then
    err("malformed config/task-types.json - types[\($i)] must be an object")
  else
    (if (.name | one_line | not) then "types[\($i)]"
     elif (.name | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not) then "types[\($i)]"
     else "type '\(.name)'" end) as $where
    | ([keys[] | select(. as $k | allowed | index($k) | not)] | .[0]) as $unknown
    | if $unknown != null then
        err("malformed config/task-types.json - \($where) has unknown field '\($unknown)'")
      elif (.name | one_line | not) then
        field_err($where; "name"; "must be a lowercase slug")
      elif (.name | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not) then
        field_err($where; "name"; "must be a lowercase slug")
      else
        (take_required($where; "use")) as $use
        | if ($use.ok | not) then $use
          else (take_required($where; "hand_back")) as $hand
          | if ($hand.ok | not) then $hand
            else (take_required($where; "touch")) as $touch
            | if ($touch.ok | not) then $touch
              else (take_optional_line($where; "check")) as $check
              | if ($check.ok | not) then $check
                else (pointers($where; "skills")) as $skills
                | if ($skills.ok | not) then $skills
                  else (pointers($where; "agents")) as $agents
                  | if ($agents.ok | not) then $agents
                    else (pointers($where; "tools")) as $tools
                    | if ($tools.ok | not) then $tools
                    else (take_model($where)) as $model
                    | if ($model.ok | not) then $model
                      else (take_effort($where)) as $effort
                      | if ($effort.ok | not) then $effort
                        else (take_projects($where)) as $projects
                        | if ($projects.ok | not) then $projects
                          else
                            {ok: true,
                             type: {
                               name: .name,
                               use: $use.value,
                               skills: $skills.items,
                               agents: $agents.items,
                               tools: $tools.items,
                               check: $check.value,
                               hand_back: $hand.value,
                               model: $model.value,
                               effort: $effort.value,
                               touch: $touch.value,
                               projects: $projects.value
                             }}
                          end
                      end
                    end
                  end
                end
              end
            end
          end
        end
        end
      end
  end;

if type != "object" then
  err("malformed config/task-types.json - the catalog must be a JSON object")
elif ([keys[] | select(. != "types")] | .[0]) != null then
  err("malformed config/task-types.json - unknown field '\([keys[] | select(. != "types")][0])'")
elif (.types | type) != "array" then
  err("malformed config/task-types.json - types must be an array")
else
  .types as $types
  | reduce range(0; $types | length) as $i ({ok: true, types: []};
      if (.ok | not) then .
      else
        ($types[$i] | one_type($i)) as $got
        | if ($got.ok | not) then $got
          else .types += [$got.type]
          end
      end)
  | if (.ok | not) then .
    else
      (reduce .types[] as $t ({}; .[$t.name] += 1) | to_entries | map(select(.value > 1)) | .[0].key) as $dup
      | if $dup != null then err("malformed config/task-types.json - duplicate type name '\($dup)'")
        else .
        end
    end
end
JQ

# shellcheck disable=SC2034 # Consumed by fm_task_type_render below.
IFS= read -r -d '' FM_TASK_TYPE_RENDER_FILTER <<'JQ' || true
def lines:
  ["## Task type", "Name: \(.name)", "Use: \(.use)"]
  + (if (.skills | length) > 0 then ["Skills: \(.skills | join(", "))"] else [] end)
  + (if (.agents | length) > 0 then ["Agents: \(.agents | join(", "))"] else [] end)
  + (if (.tools | length) > 0 then ["Tools: \(.tools | join(", ")) - use these, and name any substitute when you hand back"] else [] end)
  + (if .check != "" then ["Check: \(.check)"] else [] end)
  + ["Hand back: \(.hand_back)", "May touch: \(.touch)"];

.types as $all
| [$all[] | select(.name == $name)] as $hits
| if ($hits | length) == 0 then
    {ok: false, error: "unknown task type '\($name)'"}
  else
    $hits[0] as $t
    | if $t.projects != null and (($t.projects | index($project)) == null) then
        {ok: false, error: "task type '\($name)' does not apply to project '\($project)'"}
      else
        {
          ok: true,
          section: ($t | lines | join("\n")),
          profile: (
            [ (if $t.model != null then "model=\($t.model)" else empty end),
              (if $t.effort != null then "effort=\($t.effort)" else empty end) ]
            | if length == 0 then "" else "type-profile: " + join(" ") end
          )
        }
      end
  end
JQ

fm_task_type_read() { # <config-dir>
  local config=$1 file parsed
  file="$config/task-types.json"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 2
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file must be a readable regular file" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: $file needs jq" >&2
    return 1
  fi
  if ! parsed=$(jq -c "$FM_TASK_TYPE_LOAD_FILTER" "$file" 2>/dev/null) || [ -z "$parsed" ] || [[ "$parsed" == *$'\n'* ]]; then
    echo "error: malformed config/task-types.json - malformed JSON" >&2
    return 1
  fi
  if [ "$(jq -r '.ok' <<<"$parsed")" != true ]; then
    echo "error: $(jq -r '.error' <<<"$parsed")" >&2
    return 1
  fi
  printf '%s\n' "$parsed"
}

fm_task_type_list() { # <config-dir>
  local parsed rc=0
  parsed=$(fm_task_type_read "$1") || rc=$?
  if [ "$rc" -eq 2 ]; then
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  jq -r '.types[] | "\(.name): \(.use)"' <<<"$parsed"
}

fm_task_type_render() { # <config-dir> <name> <project>
  local parsed rc=0 result
  FM_TASK_TYPE_SECTION=
  FM_TASK_TYPE_PROFILE=
  parsed=$(fm_task_type_read "$1") || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "error: no task-type catalog: $1/task-types.json" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  if ! result=$(jq -c --arg name "$2" --arg project "$3" "$FM_TASK_TYPE_RENDER_FILTER" <<<"$parsed"); then
    echo "error: malformed config/task-types.json - could not be read" >&2
    return 1
  fi
  if [ "$(jq -r '.ok' <<<"$result")" != true ]; then
    echo "error: $(jq -r '.error' <<<"$result")" >&2
    return 1
  fi
  FM_TASK_TYPE_SECTION=$(jq -r '.section' <<<"$result")
  FM_TASK_TYPE_PROFILE=$(jq -r '.profile' <<<"$result")
}
