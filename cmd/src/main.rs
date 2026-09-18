use wellen::{
    Hierarchy, Scope, ScopeRef, Signal, SignalRef, SignalSource, SignalValueRef, TimeTable,
    TimescaleUnit, LoadOptions,
};
use wellen::viewers::{read_body, read_header_from_file};
use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};
use std::ops::Index;
use std::fs::File;
use std::collections::HashMap;

// ─── Data structures for msgpack protocol ───

#[derive(Deserialize)]
#[cfg_attr(test, derive(Serialize))]
struct Request {
    cmd: String,
    request_id: Option<u64>,
    file: Option<String>,
    id: Option<u32>,
    signal_ids: Option<Vec<u32>>,
    search_query: Option<String>,
    scope_id: Option<u32>,
    start_index: Option<u32>,
    time_start: Option<u64>,
    time_end: Option<u64>,
    max_points: Option<usize>,
}

#[derive(Serialize)]
#[cfg_attr(test, derive(serde::Deserialize))]
struct Response {
    request_id: u64,
    success: bool,
    #[serde(with = "rmpv_serde")]
    data: rmpv::Value,
    error: Option<String>,
    chunk: Option<bool>,
}

mod rmpv_serde {
    use serde::{Serialize, Serializer};
    #[cfg(test)] use serde::{Deserialize, Deserializer};

    pub fn serialize<S>(val: &rmpv::Value, serializer: S) -> Result<S::Ok, S::Error>
    where S: Serializer
    {
        val.serialize(serializer)
    }

    #[cfg(test)]
    pub fn deserialize<'de, D>(deserializer: D) -> Result<rmpv::Value, D::Error>
    where D: Deserializer<'de>
    {
        rmpv::Value::deserialize(deserializer)
    }
}

#[derive(Serialize)]
struct FileInfo {
    format: String,
    scope_count: u32,
    var_count: u32,
    time_unit: String,
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
    value_changes: Vec<(u64, String)>,
    #[serde(skip_serializing_if = "Option::is_none")]
    period: Option<u64>,
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

// ─── Error type ───

#[derive(Debug)]
enum AppError {
    NoFile,
    Io(io::Error),
    Wellen(String),
    Serialize(String),
    Illegal(u32),
    File(String),
}

impl std::fmt::Display for AppError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AppError::NoFile => write!(f, "No file loaded"),
            AppError::Io(e) => write!(f, "I/O error: {}", e),
            AppError::Wellen(s) => write!(f, "{}", s),
            AppError::Serialize(s) => write!(f, "Serialize error: {}", s),
            AppError::Illegal(id) => write!(f, "Invalid scope ID: {}", id),
            AppError::File(s) => write!(f, "{}", s),
        }
    }
}

impl From<io::Error> for AppError { fn from(e: io::Error) -> Self { AppError::Io(e) } }

fn to_msgpack<T: Serialize>(val: &T) -> Result<rmpv::Value, AppError> {
    let bytes = rmp_serde::to_vec_named(val).map_err(|e| AppError::Serialize(e.to_string()))?;
    rmpv::decode::read_value(&mut std::io::Cursor::new(&bytes)).map_err(|e| AppError::Serialize(e.to_string()))
}

// ─── Global state ───

struct CachedSignal {
    signal: Signal,
    period: Option<u64>,
}

struct AppState {
    hierarchy: Option<Hierarchy>,
    signal_source: Option<SignalSource>,
    time_table: Option<TimeTable>,
    time_unit: String,
    time_end: u64,
    param_table: Option<HashMap<u32, String>>,
    signal_cache: HashMap<SignalRef, CachedSignal>,
}

impl AppState {
    fn new() -> Self {
        AppState {
            hierarchy: None,
            signal_source: None,
            time_table: None,
            time_unit: "ns".to_string(),
            time_end: 0,
            param_table: None,
            signal_cache: HashMap::new(),
        }
    }
}

// ─── Msgpack framing helpers ───

const MAX_FRAME_LEN: usize = 512 * 1024 * 1024;

fn read_frame(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_le_bytes(len_buf) as usize;
    if len > MAX_FRAME_LEN {
        return Err(io::Error::other(format!("frame length {} exceeds max {}", len, MAX_FRAME_LEN)));
    }
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    Ok(buf)
}

fn write_frame(writer: &mut impl Write, payload: &[u8]) -> io::Result<()> {
    let len = payload.len() as u32;
    writer.write_all(&len.to_le_bytes())?;
    writer.write_all(payload)
}

fn to_value_or_nil<T: Serialize>(val: &T) -> rmpv::Value {
    rmp_serde::to_vec_named(val)
        .ok()
        .and_then(|bytes| rmpv::decode::read_value(&mut std::io::Cursor::new(&bytes)).ok())
        .unwrap_or(rmpv::Value::Nil)
}

fn send_response(
    writer: &mut impl Write,
    request_id: u64,
    success: bool,
    data: rmpv::Value,
    error: Option<String>,
    chunk: Option<bool>,
) -> io::Result<()> {
    let resp = Response {
        request_id,
        success,
        data,
        error,
        chunk,
    };
    match rmp_serde::to_vec_named(&resp) {
        Ok(payload) => {
            write_frame(writer, &payload)?;
            writer.flush()
        }
        Err(e) => {
            // Even the fallback serialization can fail; try to write an error frame
            let fallback = Response {
                request_id,
                success: false,
                data: rmpv::Value::Nil,
                error: Some(format!("Serialization error: {}", e)),
                chunk: None,
            };
            if let Ok(payload) = rmp_serde::to_vec_named(&fallback) {
                write_frame(writer, &payload)?;
                writer.flush()
            } else {
                // Cannot serialize even the fallback — propagate the write error
                Err(io::Error::other("Fatal serialization failure"))
            }
        }
    }
}

fn send_chunk(writer: &mut impl Write, request_id: u64, data: rmpv::Value) -> io::Result<()> {
    send_response(writer, request_id, true, data, None, Some(true))
}

fn send_final(writer: &mut impl Write, request_id: u64, data: rmpv::Value) -> io::Result<()> {
    send_response(writer, request_id, true, data, None, Some(false))
}

fn send_error(writer: &mut impl Write, request_id: u64, error: String) -> io::Result<()> {
    send_response(writer, request_id, false, rmpv::Value::Nil, Some(error), Some(false))
}

// ─── Command handlers ───

fn cmd_open(state: &mut AppState, path: &str) -> Result<rmpv::Value, AppError> {
    File::open(path).map_err(|e| AppError::File(e.to_string()))?;

    let load_opts = LoadOptions {
        multi_thread: true,
        remove_scopes_with_empty_name: false,
    };

    let header = read_header_from_file(path, &load_opts)
        .map_err(|e| AppError::Wellen(format!("Failed to read header: {:?}", e)))?;

    let hierarchy = header.hierarchy;
    let body = header.body;

    let scope_count = hierarchy.all_scopes().count() as u32;
    let var_count = hierarchy.all_vars().count() as u32;

    let time_unit = match hierarchy.timescale() {
        Some(scale) => {
            match scale.unit {
                TimescaleUnit::Seconds => "s",
                TimescaleUnit::MilliSeconds => "ms",
                TimescaleUnit::MicroSeconds => "us",
                TimescaleUnit::NanoSeconds => "ns",
                TimescaleUnit::PicoSeconds => "ps",
                TimescaleUnit::FemtoSeconds => "fs",
                TimescaleUnit::AttoSeconds => "as",
                TimescaleUnit::ZeptoSeconds => "zs",
                TimescaleUnit::Unknown => "s",
            }.to_string()
        }
        None => "ns".to_string(),
    };

    let body_result = read_body(body, &hierarchy, None)
        .map_err(|e| AppError::Wellen(format!("Failed to read body: {:?}", e)))?;

    let time_table = body_result.time_table;
    let mut signal_source = body_result.source;

    let param_ids: Vec<SignalRef> = hierarchy.all_vars()
        .filter(|v| v.var_type() == wellen::VarType::Parameter)
        .map(|v| v.signal_ref())
        .collect();

    let mut param_table = HashMap::new();
    if !param_ids.is_empty() {
        let param_signals = signal_source.load_signals(&param_ids, &hierarchy, false);
        for signal in param_signals {
            let signal_ref = signal.signal_ref();
            if let Some(idx) = signal.get_first_time_idx() {
                if let Some(offset) = signal.get_offset(idx) {
                    let value = signal.get_value_at(&offset, 0);
                    param_table.insert(signal_ref.index() as u32, value.to_string());
                }
            }
        }
    }
    // Overwrite unconditionally so a previous file's parameters can't leak into this one.
    state.param_table = Some(param_table);

    let event_count = time_table.len();
    let time_end = if event_count > 0 { time_table[event_count - 1] } else { 0 };

    let top_scopes: Vec<ScopeInfo> = hierarchy.scopes().map(|s| {
        let scope = hierarchy.index(s);
        ScopeInfo {
            name: scope.name(&hierarchy).to_string(),
            id: s.index() as u32,
            scope_type: format!("{:?}", scope.scope_type()),
        }
    }).collect();

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
    state.time_end = time_end;
    state.signal_cache.clear();

    let info = FileInfo {
        format: format!("{:?}", header.file_format),
        scope_count,
        var_count,
        time_unit,
        time_end,
        event_count,
        top_scopes,
        top_vars,
    };

    to_msgpack(&info)
}

fn cmd_get_children(state: &AppState, id: u32, start_index: u32) -> Result<rmpv::Value, AppError> {
    let hierarchy = state.hierarchy.as_ref().ok_or(AppError::NoFile)?;
    let scope_ref = ScopeRef::from_index(id as usize).ok_or(AppError::Illegal(id))?;
    let scope = hierarchy.index(scope_ref);

    let max_return = 65000usize;
    let mut scopes_out = Vec::new();
    let mut vars_out = Vec::new();
    let mut idx = 0u32;

    for s in scope.scopes(hierarchy) {
        if idx < start_index { idx += 1; continue; }
        idx += 1;
        let child = hierarchy.index(s);
        let info = ScopeInfo {
            name: child.name(hierarchy).to_string(),
            id: s.index() as u32,
            scope_type: format!("{:?}", child.scope_type()),
        };
        scopes_out.push(info);
        if scopes_out.len() + vars_out.len() >= max_return { break; }
    }

    for v in scope.vars(hierarchy) {
        if idx < start_index { idx += 1; continue; }
        idx += 1;
        let var = hierarchy.index(v);
        let signal_ref = var.signal_ref();
        let bits = var.index();
        let (msb, lsb) = match bits {
            Some(b) => (b.msb() as i32, b.lsb() as i32),
            None => (-1, -1),
        };
        let enum_type = var.enum_type(hierarchy).map(|e| e.0.to_string()).unwrap_or_default();
        let param_value = state.param_table.as_ref()
            .and_then(|t| t.get(&(signal_ref.index() as u32)).cloned());
        let info = VarInfo {
            name: var.name(hierarchy).to_string(),
            netlist_id: v.index() as u32,
            signal_id: signal_ref.index() as u32,
            var_type: format!("{:?}", var.var_type()),
            encoding: format!("{:?}", var.signal_encoding(hierarchy)),
            width: var.length(hierarchy).unwrap_or(0),
            msb, lsb,
            enum_type,
            param_value,
        };
        vars_out.push(info);
        if scopes_out.len() + vars_out.len() >= max_return { break; }
    }

    let returned = scopes_out.len() as u32 + vars_out.len() as u32;
    let remaining = (state.hierarchy.as_ref()
        .and_then(|h| {
            let sref = ScopeRef::from_index(id as usize)?;
            let sc = h.index(sref);
            let total = sc.scopes(h).count() + sc.vars(h).count();
            Some(total as i32)
        }).unwrap_or(0)) - returned as i32 - start_index as i32;

    let result = ChildrenResult {
        scopes: scopes_out,
        vars: vars_out,
        total_returned: returned,
        remaining_items: remaining,
    };

    to_msgpack(&result)
}

fn single_bit(value: &SignalValueRef) -> Option<u8> {
    match value {
        SignalValueRef::BitVec(bits) if bits.width() == 1 => Some(bits.get_bit(0).into()),
        _ => None,
    }
}

/// Shortest rise-to-rise/fall-to-fall distance, else twice the shortest gap.
fn detect_period(signal: &Signal, time_table: &[u64]) -> Option<u64> {
    let indices = signal.time_indices();
    if indices.len() < 3 {
        return None;
    }

    let mut min_period: Option<u64> = None;
    let mut last_edge: [Option<u64>; 2] = [None, None];
    let mut prev_bit: Option<u8> = None;
    for (tidx, value) in signal.iter_changes() {
        let Some(bit) = single_bit(&value) else { break };
        if bit <= 1 && prev_bit.is_some_and(|p| p <= 1 && p != bit) {
            let t = time_table[tidx as usize];
            if let Some(last) = last_edge[bit as usize].filter(|&last| t > last) {
                min_period = Some(min_period.map_or(t - last, |p| p.min(t - last)));
            }
            last_edge[bit as usize] = Some(t);
        }
        prev_bit = Some(bit);
    }

    min_period.or_else(|| {
        indices
            .windows(2)
            .map(|w| time_table[w[1] as usize] - time_table[w[0] as usize])
            .filter(|&gap| gap > 0)
            .min()
            .map(|gap| gap * 2)
    })
}

/// With `max_points`, keeps only the first and last change of each time bucket.
fn signal_data(
    signal: &Signal,
    time_table: &[u64],
    time_start: Option<u64>,
    start_idx: usize,
    end_idx: usize,
    max_points: Option<usize>,
) -> Vec<(u64, String)> {
    let indices = signal.time_indices();
    let time_at = |i: usize| time_table[indices[i] as usize];
    let lo = indices.partition_point(|&i| (i as usize) < start_idx);
    let hi = indices.partition_point(|&i| (i as usize) < end_idx);

    let mut value_changes: Vec<(u64, String)> = Vec::new();
    if let Some(ts) = time_start {
        if lo > 0 {
            let offset = signal.get_offset(indices[lo - 1]).expect("change exists before window");
            value_changes.push((ts, signal.get_value_at(&offset, offset.elements - 1).to_string()));
        } else if !indices.is_empty() && time_at(0) > ts {
            value_changes.push((ts, "x".to_string()));
        }
    }

    let bucket_width = max_points
        .filter(|&mp| mp >= 2 && hi - lo > mp)
        .map(|mp| (time_at(hi - 1) - time_at(lo)).div_ceil(mp as u64 / 2).max(1));
    let bucket = |i: usize, width: u64| (time_at(i) - time_at(lo)) / width;

    for (i, (_, value)) in signal.iter_changes().enumerate().skip(lo).take(hi - lo) {
        if let Some(width) = bucket_width {
            let first_in_bucket = i == lo || bucket(i - 1, width) != bucket(i, width);
            let last_in_bucket = i + 1 == hi || bucket(i + 1, width) != bucket(i, width);
            if !first_in_bucket && !last_in_bucket {
                continue;
            }
        }
        let value = value.to_string();
        if value_changes.last().is_none_or(|(_, prev)| *prev != value) {
            value_changes.push((time_at(i), value));
        }
    }
    value_changes
}

const SIGNAL_CACHE_MAX_BYTES: usize = 1 << 30;

fn load_cached(
    cache: &mut HashMap<SignalRef, CachedSignal>,
    refs: &[SignalRef],
    source: &mut SignalSource,
    hierarchy: &Hierarchy,
    time_table: &[u64],
) {
    let missing: Vec<SignalRef> = refs.iter().copied().filter(|r| !cache.contains_key(r)).collect();
    if missing.is_empty() {
        return;
    }
    let cached_bytes: usize = cache.values().map(|c| c.signal.size_in_memory()).sum();
    if cached_bytes > SIGNAL_CACHE_MAX_BYTES {
        cache.retain(|r, _| refs.contains(r));
    }
    for signal in source.load_signals(&missing, hierarchy, true) {
        let period = detect_period(&signal, time_table);
        cache.insert(signal.signal_ref(), CachedSignal { signal, period });
    }
}

fn cmd_get_signal_data(
    state: &mut AppState,
    signal_ids: &[u32],
    time_start: Option<u64>,
    time_end: Option<u64>,
    max_points: Option<usize>,
    writer: &mut impl Write,
    request_id: u64,
) -> io::Result<()> {
    let hierarchy = state.hierarchy.as_ref()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "No file loaded"))?;
    let signal_source = state.signal_source.as_mut()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "No signal source"))?;
    let time_table = state.time_table.as_ref()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "No time table"))?;

    let start_idx = time_start
        .map(|t| time_table.partition_point(|&x| x < t))
        .unwrap_or(0);
    let end_idx = time_end
        .map(|t| time_table.partition_point(|&x| x <= t))
        .unwrap_or(time_table.len());

    let mut signal_refs: Vec<SignalRef> = signal_ids.iter()
        .filter_map(|id| SignalRef::from_index(*id as usize))
        .filter(|r| hierarchy.get_signal_tpe(*r).is_some())
        .collect();
    signal_refs.sort();
    signal_refs.dedup();

    if signal_refs.is_empty() {
        return send_final(writer, request_id, rmpv::Value::Nil);
    }

    let cache = &mut state.signal_cache;
    load_cached(cache, &signal_refs, signal_source, hierarchy, time_table);

    let results: Vec<SignalDataResult> = signal_refs.iter()
        .filter_map(|r| cache.get(r))
        .map(|cached| SignalDataResult {
            signal_id: cached.signal.signal_ref().index() as u32,
            value_changes: signal_data(&cached.signal, time_table, time_start, start_idx, end_idx, max_points),
            period: cached.period,
        })
        .collect();

    for chunk in results.chunks(10) {
        send_chunk(writer, request_id, to_value_or_nil(&chunk))?;
    }
    send_final(writer, request_id, rmpv::Value::Nil)
}

const MAX_SEARCH_RESULTS: usize = 5000;

fn cmd_search(state: &AppState, query: &str, scope_id: u32) -> Result<rmpv::Value, AppError> {
    let hierarchy = state.hierarchy.as_ref().ok_or(AppError::NoFile)?;

    let lower_query = query.to_lowercase();
    let mut results = Vec::new();

    let search_scope = if scope_id != 0xFFFFFFFF {
        let sr = ScopeRef::from_index(scope_id as usize).ok_or(AppError::Illegal(scope_id))?;
        Some(hierarchy.index(sr))
    } else {
        None
    };

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

    fn scope_var_pairs<'a>(
        hierarchy: &'a Hierarchy,
        scope: &Scope,
        pairs: &mut Vec<(wellen::VarRef, &'a wellen::Var)>,
    ) {
        for vref in scope.vars(hierarchy) {
            pairs.push((vref, hierarchy.index(vref)));
        }
        for sref in scope.scopes(hierarchy) {
            scope_var_pairs(hierarchy, hierarchy.index(sref), pairs);
        }
    }

    let mut var_pairs: Vec<(wellen::VarRef, &wellen::Var)> = Vec::new();
    match search_scope {
        Some(scope) => scope_var_pairs(hierarchy, scope, &mut var_pairs),
        None => {
            for sref in hierarchy.scopes() {
                scope_var_pairs(hierarchy, hierarchy.index(sref), &mut var_pairs);
            }
        }
    }

    let path_query = lower_query.contains('.');

    for (vref, var) in &var_pairs {
        let name = var.name(hierarchy).to_lowercase();
        if name.contains(&lower_query)
            || (path_query && var.full_name(hierarchy).to_lowercase().contains(&lower_query))
        {
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
                netlist_id: vref.index() as u32,
                signal_id: sig_ref.index() as u32,
                width: w,
            });
        }
    }

    let total = results.len();
    results.truncate(MAX_SEARCH_RESULTS);

    let result = SearchResult {
        total_results: total,
        search_results: results,
    };

    to_msgpack(&result)
}

// ─── Main loop ───

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut state = AppState::new();

    let mut reader = stdin.lock();
    let mut writer = stdout.lock();

    loop {
        // Any read error desyncs the frame stream with no way to resync, so it's fatal too.
        let buf = match read_frame(&mut reader) {
            Ok(b) => b,
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => break,
            Err(e) => {
                let _ = send_error(&mut writer, 0, format!("Read error: {}", e));
                break;
            }
        };

        let req: Request = match rmp_serde::from_slice(&buf) {
            Ok(r) => r,
            Err(e) => {
                if send_error(&mut writer, 0, format!("Parse error: {}", e)).is_err() { break; }
                continue;
            }
        };

        let request_id = req.request_id.unwrap_or(0);

        let write_result = match req.cmd.as_str() {
            "get_signal_data" => {
                let ids = req.signal_ids.unwrap_or_default();
                cmd_get_signal_data(&mut state, &ids, req.time_start, req.time_end, req.max_points, &mut writer, request_id)
            }
            "open" => match &req.file {
                Some(f) => match cmd_open(&mut state, f) {
                    Ok(data) => send_final(&mut writer, request_id, data),
                    Err(e) => send_error(&mut writer, request_id, e.to_string()),
                },
                None => send_error(&mut writer, request_id, "Missing 'file' argument".to_string()),
            },
            "get_children" => match cmd_get_children(&state, req.id.unwrap_or(0), req.start_index.unwrap_or(0)) {
                Ok(data) => send_final(&mut writer, request_id, data),
                Err(e) => send_error(&mut writer, request_id, e.to_string()),
            },
            "search" => match cmd_search(&state, req.search_query.as_deref().unwrap_or(""), req.scope_id.unwrap_or(0xFFFFFFFF)) {
                Ok(data) => send_final(&mut writer, request_id, data),
                Err(e) => send_error(&mut writer, request_id, e.to_string()),
            },
            "close" => {
                state = AppState::new();
                send_final(&mut writer, request_id, rmpv::Value::Nil)
            }
            cmd => send_error(&mut writer, request_id, format!("Unknown command: {}", cmd)),
        };
        if write_result.is_err() {
            break;
        }
    }
}

// ─── Tests ───

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_frame_roundtrip() {
        let payload = b"hello msgpack";
        let mut buf = Vec::new();
        write_frame(&mut buf, payload).unwrap();
        let mut cursor = Cursor::new(&buf);
        let result = read_frame(&mut cursor).unwrap();
        assert_eq!(result, payload);
    }

    #[test]
    fn test_frame_empty() {
        let payload = b"";
        let mut buf = Vec::new();
        write_frame(&mut buf, payload).unwrap();
        let mut cursor = Cursor::new(&buf);
        let result = read_frame(&mut cursor).unwrap();
        assert_eq!(result, payload);
    }

    #[test]
    fn test_frame_large() {
        let payload = vec![0xABu8; 10000];
        let mut buf = Vec::new();
        write_frame(&mut buf, &payload).unwrap();
        let mut cursor = Cursor::new(&buf);
        let result = read_frame(&mut cursor).unwrap();
        assert_eq!(result, payload);
    }

    #[test]
    fn test_app_error_display() {
        assert_eq!(AppError::NoFile.to_string(), "No file loaded");
        assert_eq!(AppError::Illegal(42).to_string(), "Invalid scope ID: 42");
        assert_eq!(AppError::Serialize("bad".to_string()).to_string(), "Serialize error: bad");
        assert!(AppError::Io(io::Error::new(io::ErrorKind::NotFound, "x")).to_string().contains("I/O error"));
    }

    #[test]
    fn test_send_response_roundtrip() {
        let mut buf = Vec::new();
        let data = rmpv::ext::to_value(&"test_value").unwrap();
        let _ = send_response(&mut buf, 1, true, data, None, Some(false));

        let mut cursor = Cursor::new(&buf);
        let frame = read_frame(&mut cursor).unwrap();
        let resp: Response = rmp_serde::from_slice(&frame).unwrap();
        assert_eq!(resp.request_id, 1);
        assert!(resp.success);
        assert!(resp.error.is_none());
        assert_eq!(resp.chunk, Some(false));
    }

    #[test]
    fn test_send_error_response() {
        let mut buf = Vec::new();
        let _ = send_error(&mut buf, 5, "Something went wrong".to_string());

        let mut cursor = Cursor::new(&buf);
        let frame = read_frame(&mut cursor).unwrap();
        let resp: Response = rmp_serde::from_slice(&frame).unwrap();
        assert_eq!(resp.request_id, 5);
        assert!(!resp.success);
        assert_eq!(resp.error, Some("Something went wrong".to_string()));
        assert_eq!(resp.chunk, Some(false));
    }

    #[test]
    fn test_to_value_or_nil_with_serializable() {
        let val = to_value_or_nil(&42u32);
        assert_eq!(val, rmpv::Value::Integer(42.into()));
    }

    #[test]
    fn test_search_empty_query() {
        let state = AppState::new();
        let result = cmd_search(&state, "", 0xFFFFFFFF);
        assert!(result.is_err()); // No file loaded
    }

    #[test]
    fn test_children_no_file() {
        let state = AppState::new();
        let result = cmd_get_children(&state, 1, 0);
        match result {
            Err(AppError::NoFile) => {}
            _ => panic!("Expected NoFile error, got {:?}", result),
        }
    }

    #[test]
    fn test_open_nonexistent_file() {
        let mut state = AppState::new();
        let result = cmd_open(&mut state, "/nonexistent/foo.vcd");
        match result {
            Err(AppError::File(_)) => {}
            _ => panic!("Expected File error, got {:?}", result),
        }
    }

    #[test]
    fn test_request_deserialize() {
        let req = Request {
            cmd: "open".to_string(),
            request_id: Some(1),
            file: Some("test.vcd".to_string()),
            id: None,
            signal_ids: None,
            search_query: None,
            scope_id: None,
            start_index: None,
            time_start: None,
            time_end: None,
            max_points: None,
        };
        let encoded = rmp_serde::to_vec_named(&req).unwrap();
        let decoded: Request = rmp_serde::from_slice(&encoded).unwrap();
        assert_eq!(decoded.cmd, "open");
        assert_eq!(decoded.file, Some("test.vcd".to_string()));
    }

    fn var_len_signal(values: &[&str], step: u64) -> (Signal, Vec<u64>) {
        let n = values.len() as u32;
        let time_table = (0..n as u64).map(|i| i * step).collect();
        let values = values.iter().map(|v| v.to_string()).collect();
        (Signal::new_var_len(SignalRef::from_index(0).unwrap(), (0..n).collect(), values), time_table)
    }

    fn toggling(n: usize) -> Vec<&'static str> {
        (0..n).map(|i| if i % 2 == 0 { "0" } else { "1" }).collect()
    }

    #[test]
    fn test_decimation_keeps_toggle_activity_for_any_bucket_width() {
        let values = toggling(10_000);
        let (signal, tt) = var_len_signal(&values, 10);
        for max_points in [50, 64, 100, 128, 200, 1000] {
            let vc = signal_data(&signal, &tt, None, 0, tt.len(), Some(max_points));
            let ones = vc.iter().filter(|(_, v)| v == "1").count();
            assert!(vc.len() <= max_points, "max_points={max_points}: {} entries", vc.len());
            assert!(vc.len() >= max_points / 2, "max_points={max_points}: {} entries", vc.len());
            assert!(ones.abs_diff(vc.len() - ones) <= 1, "max_points={max_points}: unbalanced");
        }
    }

    #[test]
    fn test_signal_data_window_prepends_value_in_effect() {
        let (signal, tt) = var_len_signal(&toggling(10), 10);
        let start_idx = tt.partition_point(|&t| t < 55);
        let vc = signal_data(&signal, &tt, Some(55), start_idx, tt.len(), None);
        assert_eq!(vc[0], (55, "1".to_string()));
        assert_eq!(vc[1], (60, "0".to_string()));
        assert_eq!(vc.len(), 5);
    }

    #[test]
    fn test_signal_data_collapses_repeated_values() {
        let (signal, tt) = var_len_signal(&["0", "0", "1", "1", "0"], 10);
        let vc = signal_data(&signal, &tt, None, 0, tt.len(), None);
        assert_eq!(vc, vec![(0, "0".to_string()), (20, "1".to_string()), (40, "0".to_string())]);
    }

    #[test]
    fn test_detect_period_falls_back_to_min_gap() {
        let (signal, tt) = var_len_signal(&toggling(4), 10);
        assert_eq!(detect_period(&signal, &tt), Some(20));
        let (short, tt) = var_len_signal(&toggling(2), 10);
        assert_eq!(detect_period(&short, &tt), None);
    }
}
