-- Luacheck config for the skyflow-ai-data-control plugin (docs/05 §5.5).
std = "ngx_lua"
unused_args = false
redefined = false
max_line_length = 120

globals = {
  "kong",
  "ngx",
}

not_globals = {
  "string.len",
  "table.getn",
}

include_files = {
  "plugin/**/*.lua",
  "kong/**/*.lua",
  "spec/**/*.lua",
  "*.rockspec",
}

exclude_files = {
  ".luarocks/**",
  "lua_modules/**",
}

files["spec/**/*.lua"] = {
  std = "ngx_lua+busted",
}
