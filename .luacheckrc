std = "luajit"
globals = { "vim" }
max_line_length = 120
exclude_files = { "cmd/target" }

files["tests/*.lua"] = {
  ignore = { "211", "212", "213" },
}
