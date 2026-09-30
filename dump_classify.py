import zipfile, struct

with zipfile.ZipFile('../tools/ACBNEW-7.apk') as z:
    dex = z.read('classes.dex')

string_ids_size, string_ids_off = struct.unpack_from("<II", dex, 56)
type_ids_size, type_ids_off = struct.unpack_from("<II", dex, 64)
field_ids_size, field_ids_off = struct.unpack_from("<II", dex, 80)
method_ids_size, method_ids_off = struct.unpack_from("<II", dex, 88)
class_defs_size, class_defs_off = struct.unpack_from("<II", dex, 96)

def get_string(idx):
    off = struct.unpack_from("<I", dex, string_ids_off + idx * 4)[0]
    pos = off
    length = 0
    shift = 0
    while True:
        b = dex[pos]
        pos += 1
        length |= (b & 0x7f) << shift
        if not (b & 0x80): break
        shift += 7
    end = dex.find(b"\x00", pos)
    return dex[pos:end].decode("utf-8", errors="ignore")

def get_type(idx):
    return get_string(struct.unpack_from("<I", dex, type_ids_off + idx * 4)[0])

def get_method(idx):
    class_idx, proto_idx, name_idx = struct.unpack_from("<HHI", dex, method_ids_off + idx * 8)
    return f"{get_type(class_idx)}->{get_string(name_idx)}"

def get_field(idx):
    class_idx, type_idx, name_idx = struct.unpack_from("<HHI", dex, field_ids_off + idx * 8)
    return f"{get_type(class_idx)}->{get_string(name_idx)}"

def read_uleb128(pos):
    result = 0
    shift = 0
    while True:
        b = dex[pos]
        pos += 1
        result |= (b & 0x7f) << shift
        if not (b & 0x80): break
        shift += 7
    return result, pos

for i in range(class_defs_size):
    class_idx, access_flags, superclass_idx, interfaces_off, source_file_idx, annotations_off, class_data_off, static_values_off = struct.unpack_from("<IIIIIIII", dex, class_defs_off + i * 32)
    if class_data_off == 0: continue
    pos = class_data_off
    s_f, pos = read_uleb128(pos)
    i_f, pos = read_uleb128(pos)
    d_m, pos = read_uleb128(pos)
    v_m, pos = read_uleb128(pos)
    for _ in range(s_f + i_f):
        _, pos = read_uleb128(pos)
        _, pos = read_uleb128(pos)
    m_idx = 0
    for _ in range(d_m + v_m):
        diff, pos = read_uleb128(pos)
        m_idx += diff
        flags, pos = read_uleb128(pos)
        code_off, pos = read_uleb128(pos)
        mname = get_method(m_idx)
        if "classify" in mname.lower() or "validat" in mname.lower() or "face" in mname.lower():
            if "classifyNativeFace" in mname:
                print(f"=== {mname} at {code_off} ===")
                regs, ins, outs, tries, debug_off, insns_size = struct.unpack_from('<HHHHII', dex, code_off)
                print(f"regs={regs}, ins={ins}, outs={outs}, insns_size={insns_size}")
                raw = dex[code_off+16:code_off+16+insns_size*2]
                # Print hex and ops
                k = 0
                while k < len(raw):
                    op = raw[k]
                    extra = ""
                    if op in [0x6e, 0x6f, 0x70, 0x71, 0x72]:
                        ref = struct.unpack_from('<H', raw, k+2)[0]
                        extra = f"call {get_method(ref)}"
                        k_step = 6
                    elif op in range(0x52, 0x68):
                        ref = struct.unpack_from('<H', raw, k+2)[0]
                        extra = f"field {get_field(ref)}"
                        k_step = 4
                    elif op == 0x14: # const
                        val = struct.unpack_from('<i', raw, k+2)[0]
                        fval = struct.unpack_from('<f', raw, k+2)[0]
                        extra = f"const# {val} ({fval})"
                        k_step = 6
                    elif op == 0x15: # const/high16
                        val = struct.unpack_from('<h', raw, k+2)[0] << 16
                        fval = struct.unpack_from('<f', struct.pack('<i', val))[0]
                        extra = f"const/high16 {fval}"
                        k_step = 4
                    elif op in [0x12, 0x13]:
                        k_step = 2 if op == 0x12 else 4
                    elif op == 0x1a:
                        ref = struct.unpack_from('<H', raw, k+2)[0]
                        extra = f'str "{get_string(ref)}"'
                        k_step = 4
                    else:
                        k_step = 2
                    print(f"  {k//2:04x}: op=0x{op:02x} {extra}")
                    k += k_step
