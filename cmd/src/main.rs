use wellen::{
    FileFormat, Hierarchy, ScopeRef, SignalRef, SignalSource, TimeTable,
    TimescaleUnit, VarRef, LoadOptions,
};
use wellen::viewers::{read_body, read_header};
use serde::{Deserialize, Serialize};
use std::io::{self, BufRead, BufReader, Write};
use std::ops::Index;
use std::fs::File;
use std::collections::HashMap;

// ─── Data structures for JSON protocol ───

#[derive(Deserialize)]
struct Request {
    cmd: String,
    request_id: Option<u64>,
    file: Option<String>,
    id: Option<u32>,
    signal_ids: Option<Vec<u32>>,
    search_query: Option<String>,
    scope_id: Option<u32>,
    paths: Option<Vec<String>>,
    netlist_ids: Option<Vec<u32>>,
    start_index: Option<u32>,
}

#[derive(Serialize)]
struct Response {
    request_id: u64,
    success: bool,
    data: serde_json::Value,
    error: Option<String>,
}

#[derive(Serialize)]
struct FileInfo {
    format: String,
    scope_count: u32,
    var_count: u32,
    time_unit: String,
    time_scale: u32,
    time_end: u64,
    event_count: usize,
    top_scopes: Vec<ScopeInfo>,
    top_vars: Vec<VarInfo>,
}

#[derive(Serialize)]
struct ScopeInfo {
    name: String,
    id: u32,
    scope_type: String,
}

#[derive(Serialize)]
struct VarInfo {
    name: String,
    netlist_id: u32,
    signal_id: u32,
    var_type: String,
    encoding: String,
    width: u32,
    msb: i32,
    lsb: i32,
    enum_type: String,
    param_value: Option<String>,
}

#[derive(Serialize)]
struct ChildrenResult {
    scopes: Vec<ScopeInfo>,
    vars: Vec<VarInfo>,
    total_returned: u32,
    remaining_items: i32,
}

#[derive(Serialize)]
struct SignalDataResult {
    signal_id: u32,
    value_changes: Vec<[String; 2]>,
    min: f64,
    max: f64,
}

#[derive(Serialize)]
struct SearchEntry {
    instance_path: String,
    item_type: String,
    is_var: bool,
    param_value: String,
    msb: i32,
    lsb: i32,
    netlist_id: u32,
    signal_id: u32,
    width: u32,
}

#[derive(Serialize)]
struct SearchResult {
    total_results: usize,
    search_results: Vec<SearchEntry>,
}

#[derive(Serialize)]
struct ValuesAtTimeResult {
    instance_path: String,
    value: String,
}

// ─── Global state ───

struct AppState {
    hierarchy: Option<Hierarchy>,
    signal_source: Option<SignalSource>,
    time_table: Option<TimeTable>,
    file_format: FileFormat,
    time_unit: String,
    time_scale: u32,
    time_end: u64,
    param_table: Option<HashMap<u32, String>>,
}

impl AppState {
    fn new() -> Self {
        AppState {
            hierarchy: None,
            signal_source: None,
            time_table: None,
            file_format: FileFormat::Unknown,
            time_unit: "ns".to_string(),
            time_scale: 1,
            time_end: 0,
            param_table: None,
        }
    }
}

// ─── Command handlers ───

fn cmd_open(state: &mut AppState, path: &str) -> Result<serde_json::Value, String> {
    let file = File::open(path).map_err(|e| format!("Cannot open file: {}", e))?;

    let load_opts = LoadOptions {
        multi_thread: false,
        remove_scopes_with_empty_name: false,
    };

    let reader = BufReader::new(file);
    let header = read_header(reader, &load_opts)
        .map_err(|e| format!("Failed to read header: {:?}", e))?;

    let hierarchy = header.hierarchy;
    state.file_format = header.file_format;
    let body = header.body;

    // Count scopes and vars
    let scope_count = hierarchy.all_scopes().count() as u32;
    let var_count = hierarchy.all_vars().count() as u32;

    // Time scale
    let (time_unit, time_scale) = match hierarchy.timescale() {
        Some(scale) => {
            let unit = match scale.unit {
                TimescaleUnit::Seconds => "s",
                TimescaleUnit::MilliSeconds => "ms",
                TimescaleUnit::MicroSeconds => "us",
                TimescaleUnit::NanoSeconds => "ns",
                TimescaleUnit::PicoSeconds => "ps",
                TimescaleUnit::FemtoSeconds => "fs",
                TimescaleUnit::AttoSeconds => "as",
                TimescaleUnit::ZeptoSeconds => "zs",
                TimescaleUnit::Unknown => "s",
            };
            (unit.to_string(), scale.factor as u32)
        }
        None => ("ns".to_string(), 1),
    };

    // Read body for time table and signal source
    let body_result = read_body(body, &hierarchy, None)
        .map_err(|e| format!("Failed to read body: {:?}", e))?;

    let time_table = body_result.time_table;
    let mut signal_source = body_result.source;

    // Load parameters
    let param_ids: Vec<SignalRef> = hierarchy.all_vars()
        .filter(|v| v.var_type() == wellen::VarType::Parameter)
        .map(|v| v.signal_ref())
        .collect();

    if !param_ids.is_empty() {
        let param_signals = signal_source.load_signals(&param_ids, &hierarchy, false);
        let mut param_table = HashMap::new();
        for signal in param_signals {
            let signal_ref = signal.signal_ref();
            if let Some(idx) = signal.get_first_time_idx() {
                if let Some(offset) = signal.get_offset(idx) {
                    let value = signal.get_value_at(&offset, 0);
                    param_table.insert(signal_ref.index() as u32, value.to_string());
                }
            }
        }
        state.param_table = Some(param_table);
    }

    let event_count = time_table.len();
    let time_end = if event_count > 0 { time_table[event_count - 1] } else { 0 };

    // Top-level scopes
    let top_scopes: Vec<ScopeInfo> = hierarchy.scopes().map(|s| {
        let scope = hierarchy.index(s);
        ScopeInfo {
            name: scope.name(&hierarchy).to_string(),
            id: s.index() as u32,
            scope_type: format!("{:?}", scope.scope_type()),
        }
    }).collect();

    // Top-level vars
    let top_vars: Vec<VarInfo> = hierarchy.vars().map(|v| {
        let var = hierarchy.index(v);
        let signal_ref = var.signal_ref();
        let bits = var.index();
        let (msb, lsb) = match bits {
            Some(b) => (b.msb() as i32, b.lsb() as i32),
            None => (-1, -1),
        };
        let enum_type = var.enum_type(&hierarchy).map(|e| e.0.to_string()).unwrap_or_default();
        let param_value = state.param_table.as_ref()
            .and_then(|t| t.get(&(signal_ref.index() as u32)).cloned());
        VarInfo {
            name: var.name(&hierarchy).to_string(),
            netlist_id: v.index() as u32,
            signal_id: signal_ref.index() as u32,
            var_type: format!("{:?}", var.var_type()),
            encoding: format!("{:?}", var.signal_encoding(&hierarchy)),
            width: var.length(&hierarchy).unwrap_or(0),
            msb, lsb,
            enum_type,
            param_value,
        }
    }).collect();

    state.hierarchy = Some(hierarchy);
    state.signal_source = Some(signal_source);
    state.time_table = Some(time_table);
    state.time_unit = time_unit.clone();
    state.time_scale = time_scale;
    state.time_end = time_end;

    let info = FileInfo {
        format: format!("{:?}", state.file_format),
        scope_count,
        var_count,
        time_unit,
        time_scale,
        time_end,
        event_count,
        top_scopes,
        top_vars,
    };

    serde_json::to_value(info).map_err(|e| format!("Serialize error: {}", e))
}

fn cmd_get_children(state: &AppState, id: u32, start_index: u32) -> Result<serde_json::Value, String> {
    let hierarchy = state.hierarchy.as_ref().ok_or("No file loaded")?;
    let scope_ref = ScopeRef::from_index(id as usize).ok_or("Invalid scope ID")?;
    let scope = hierarchy.index(scope_ref);

    let max_return = 65000usize;
    let mut result_len = 0usize;
    let mut scopes_out = Vec::new();
    let mut vars_out = Vec::new();
    let mut idx = 0u32;
    let mut total_scopes = 0u32;
    let mut total_vars = 0u32;

    for s in scope.scopes(&hierarchy) {
        total_scopes += 1;
        if idx < start_index || result_len > max_return { idx += 1; continue; }
        idx += 1;
        let child = hierarchy.index(s);
        let info = ScopeInfo {
            name: child.name(&hierarchy).to_string(),
            id: s.index() as u32,
            scope_type: format!("{:?}", child.scope_type()),
        };
        let s = serde_json::to_string(&info).unwrap_or_default();
        result_len += s.len();
        scopes_out.push(info);
    }

    for v in scope.vars(&hierarchy) {
        total_vars += 1;
        if idx < start_index || result_len > max_return { idx += 1; continue; }
        idx += 1;
        let var = hierarchy.index(v);
        let signal_ref = var.signal_ref();
        let bits = var.index();
        let (msb, lsb) = match bits {
            Some(b) => (b.msb() as i32, b.lsb() as i32),
            None => (-1, -1),
        };
        let enum_type = var.enum_type(&hierarchy).map(|e| e.0.to_string()).unwrap_or_default();
        let param_value = state.param_table.as_ref()
            .and_then(|t| t.get(&(signal_ref.index() as u32)).cloned());
        let info = VarInfo {
            name: var.name(&hierarchy).to_string(),
            netlist_id: v.index() as u32,
            signal_id: signal_ref.index() as u32,
            var_type: format!("{:?}", var.var_type()),
            encoding: format!("{:?}", var.signal_encoding(&hierarchy)),
            width: var.length(&hierarchy).unwrap_or(0),
            msb, lsb,
            enum_type,
            param_value,
        };
        let s = serde_json::to_string(&info).unwrap_or_default();
        result_len += s.len();
        vars_out.push(info);
    }

    let total_items = total_scopes + total_vars;
    let returned = scopes_out.len() as u32 + vars_out.len() as u32;
    let remaining = total_items as i32 - (returned as i32 + start_index as i32);

    let result = ChildrenResult {
        scopes: scopes_out,
        vars: vars_out,
        total_returned: returned,
        remaining_items: remaining,
    };

    serde_json::to_value(result).map_err(|e| format!("Serialize error: {}", e))
}

fn cmd_get_signal_data(state: &mut AppState, signal_ids: &[u32]) -> Result<serde_json::Value, String> {
    let hierarchy = state.hierarchy.as_ref().ok_or("No file loaded")?;
    let signal_source = state.signal_source.as_mut().ok_or("No signal source")?;
    let time_table = state.time_table.as_ref().ok_or("No time table")?;

    let mut signal_refs: Vec<SignalRef> = Vec::new();
    for id in signal_ids {
        let sr = SignalRef::from_index(*id as usize).ok_or("Invalid signal ID")?;
        signal_refs.push(sr);
    }

    let signals = signal_source.load_signals(&signal_refs, hierarchy, false);

    let mut results = Vec::new();
    for signal in &signals {
        let sig_ref = signal.signal_ref();
        let sig_id = sig_ref.index() as u32;
        let time_indices = signal.time_indices();
        let transitions = signal.iter_changes();

        let mut value_changes: Vec<[String; 2]> = Vec::new();
        let mut min = 0.0f64;
        let mut max = 0.0f64;

        for (i, (_, value)) in transitions.enumerate() {
            let t = if i < time_indices.len() {
                time_table[time_indices[i] as usize]
            } else {
                0
            };
            let v = value.to_string();

            if let wellen::SignalValueRef::Real(r) = value {
                if i == 0 { min = r; max = r; }
                else { min = min.min(r); max = max.max(r); }
            }

            value_changes.push([t.to_string(), v]);
        }

        results.push(SignalDataResult {
            signal_id: sig_id,
            value_changes,
            min,
            max,
        });
    }

    serde_json::to_value(results).map_err(|e| format!("Serialize error: {}", e))
}

fn cmd_search(state: &AppState, query: &str, scope_id: u32) -> Result<serde_json::Value, String> {
    let hierarchy = state.hierarchy.as_ref().ok_or("No file loaded")?;

    if query.is_empty() {
        return serde_json::to_value(SearchResult {
            total_results: 0,
            search_results: vec![],
        }).map_err(|e| format!("Serialize error: {}", e));
    }

    let lower_query = query.to_lowercase();

    let search_scope = if scope_id != 0xFFFFFFFF {
        ScopeRef::from_index(scope_id as usize).map(|sr| hierarchy.index(sr))
    } else {
        None
    };

    let mut results = Vec::new();

    // Search scopes
    let all_scopes: Vec<_> = match search_scope {
        Some(s) => {
            let mut v = vec![s];
            v.extend(s.scopes(hierarchy).map(|sr| hierarchy.index(sr)));
            v
        }
        None => hierarchy.all_scopes().collect(),
    };

    for scope in &all_scopes {
        let name = scope.name(hierarchy).to_string().to_lowercase();
        if name.contains(&lower_query) {
            results.push(SearchEntry {
                instance_path: scope.full_name(hierarchy).to_string(),
                item_type: format!("{:?}", scope.scope_type()),
                is_var: false,
                param_value: String::new(),
                msb: -1,
                lsb: -1,
                netlist_id: 0,
                signal_id: 0,
                width: 0,
            });
        }
    }

    for var in hierarchy.all_vars() {
        let name = var.name(hierarchy).to_string().to_lowercase();
        if name.contains(&lower_query) {
            let param_value = state.param_table.as_ref()
                .and_then(|t| t.get(&(var.signal_ref().index() as u32)))
                .cloned()
                .unwrap_or_default();
            let bits = var.index();
            let (msb, lsb) = match bits {
                Some(b) => (b.msb() as i32, b.lsb() as i32),
                None => (-1, -1),
            };
            let sig_ref = var.signal_ref();
            let w = var.length(hierarchy).unwrap_or(1);
            results.push(SearchEntry {
                instance_path: var.full_name(hierarchy).to_string(),
                item_type: format!("{:?}", var.var_type()),
                is_var: true,
                param_value,
                msb,
                lsb,
                netlist_id: sig_ref.index() as u32,
                signal_id: sig_ref.index() as u32,
                width: w,
            });
        }
    }

    let total = results.len();
    results.truncate(100);

    let result = SearchResult {
        total_results: total,
        search_results: results,
    };

    serde_json::to_value(result).map_err(|e| format!("Serialize error: {}", e))
}

fn cmd_get_values_at_time(state: &AppState, paths: &[String]) -> Result<serde_json::Value, String> {
    let hierarchy = state.hierarchy.as_ref().ok_or("No file loaded")?;

    let mut signal_refs = Vec::new();
    let mut path_map: Vec<(String, SignalRef)> = Vec::new();

    for path in paths {
        let parts: Vec<&str> = path.split('.').collect();
        let name = parts.last().unwrap_or(&"");
        let scope_path = &parts[..parts.len().saturating_sub(1)];
        if let Some(var_ref) = hierarchy.lookup_var(scope_path, name) {
            let var = hierarchy.index(var_ref);
            let sr = var.signal_ref();
            signal_refs.push(sr);
            path_map.push((path.clone(), sr));
        }
    }

    // We need a mutable signal source, but the API requires it
    // For now, return empty
    let result: Vec<ValuesAtTimeResult> = Vec::new();
    serde_json::to_value(result).map_err(|e| format!("Serialize error: {}", e))
}

fn cmd_get_enum_data(state: &AppState, netlist_ids: &[u32]) -> Result<serde_json::Value, String> {
    let hierarchy = state.hierarchy.as_ref().ok_or("No file loaded")?;
    let mut enum_map = serde_json::Map::new();

    for id in netlist_ids {
        if let Some(var_ref) = VarRef::from_index(*id as usize) {
            let var = hierarchy.index(var_ref);
            if let Some((name, values)) = var.enum_type(&hierarchy) {
                if let Ok(val) = serde_json::to_value(&values) {
                    enum_map.insert(name.to_string(), val);
                }
            }
        }
    }

    Ok(serde_json::Value::Object(enum_map))
}

// ─── Main loop ───

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut state = AppState::new();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };

        if line.trim().is_empty() {
            continue;
        }

        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let resp = Response {
                    request_id: 0,
                    success: false,
                    data: serde_json::Value::Null,
                    error: Some(format!("Parse error: {}", e)),
                };
                let out = serde_json::to_string(&resp).unwrap();
                let mut handle = stdout.lock();
                let _ = writeln!(handle, "{}", out);
                let _ = handle.flush();
                continue;
            }
        };

        let result = match req.cmd.as_str() {
            "open" => {
                match &req.file {
                    Some(f) => cmd_open(&mut state, f),
                    None => Err("Missing 'file' argument".to_string()),
                }
            }
            "get_children" => {
                cmd_get_children(&state, req.id.unwrap_or(0), req.start_index.unwrap_or(0))
            }
            "get_signal_data" => {
                match &req.signal_ids {
                    Some(ids) => cmd_get_signal_data(&mut state, ids),
                    None => Err("Missing 'signal_ids' argument".to_string()),
                }
            }
            "search" => {
                cmd_search(&state, req.search_query.as_deref().unwrap_or(""), req.scope_id.unwrap_or(0xFFFFFFFF))
            }
            "get_values_at_time" => {
                cmd_get_values_at_time(&state, req.paths.as_deref().unwrap_or(&[]))
            }
            "get_enum_data" => {
                cmd_get_enum_data(&state, req.netlist_ids.as_deref().unwrap_or(&[]))
            }
            "close" => {
                state = AppState::new();
                Ok(serde_json::Value::Null)
            }
            _ => Err(format!("Unknown command: {}", req.cmd)),
        };

        let request_id = req.request_id.unwrap_or(0);
        let resp = match result {
            Ok(data) => Response {
                request_id,
                success: true,
                data,
                error: None,
            },
            Err(e) => Response {
                request_id,
                success: false,
                data: serde_json::Value::Null,
                error: Some(e),
            },
        };

        let out = serde_json::to_string(&resp).unwrap();
        let mut handle = stdout.lock();
        let _ = writeln!(handle, "{}", out);
        let _ = handle.flush();
    }
}
