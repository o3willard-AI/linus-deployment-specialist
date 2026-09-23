#!/usr/bin/env python3
"""
Linus Deployment Specialist — Vast Table Parser
Replaces fragile awk parsing of `vastai show instance` output.

vastai show instance outputs multi-section ASCII tables with leading
whitespace that shifts column positions. This parser handles:
- Leading whitespace (common in newer Vast CLI versions)
- Multi-section tables separated by blank lines
- Variable column widths
- Missing/empty fields
- ANSI escape codes (Vast CLI outputs terminal color codes)

Usage: vastai show instance CONTRACT_ID | python3 parse-vast-table.py FIELD [FIELD...]
  Fields: status, machine_id, host_id, ssh_host, ssh_port, price, image

Exit: 0 and prints value(s) on success, 1 on parse failure.
"""
import sys
import re

def parse_table(lines):
    """Parse Vast's multi-section table into a dict of parsed rows."""
    # Strip ANSI escape codes that Vast CLI outputs in terminal mode
    ansi_re = re.compile(r'\x1b\[[0-9;]*m')
    lines = [ansi_re.sub('', line) for line in lines]
    
    sections = []
    current_section = []
    
    for line in lines:
        stripped = line.strip()
        if not stripped:
            if current_section:
                sections.append(current_section)
                current_section = []
            continue
        current_section.append(line)
    
    if current_section:
        sections.append(current_section)
    
    result = {}
    
    # Section 1: Instance info (row#, ID, Machine, Status, Num, Model, Util.%, vCPUs, RAM, Storage)
    if sections:
        result['instance'] = _parse_section(sections[0], {
            'row': 0, 'contract_id': 1, 'machine_id': 2, 'status': 3,
            'num_gpus': 4, 'gpu_model': 5, 'util': 6,
            'vcpus': 7, 'ram': 8, 'storage': 9
        })
    
    # Section 2: SSH/Price info (row#, SSH Addr, SSH Port, $/hr, Image)
    if len(sections) > 1:
        result['ssh'] = _parse_section(sections[1], {
            'row': 0, 'ssh_host': 1, 'ssh_port': 2, 'price': 3, 'image': 4
        })
    
    # Section 3: Network info
    if len(sections) > 2:
        result['network'] = _parse_section(sections[2], {
            'row': 0, 'net_up': 1, 'net_down': 2, 'reliability': 3,
            'label': 4, 'age': 5, 'uptime': 6
        })
    
    return result


def _parse_section(lines, field_map):
    """Parse one table section, returning the first data row's fields."""
    if len(lines) < 2:
        return {}
    
    # Find the header row (contains column names) and data row
    header_idx = None
    data_idx = None
    
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        # Header row typically contains column names like 'ID', 'Status', etc.
        if re.search(r'\b(ID|Status|Machine|SSH|Net)\b', stripped):
            # Skip if it looks like a data row (starts with a digit)
            if not re.match(r'^\s*\d+', stripped):
                header_idx = i
                continue
        # Data row starts with a digit
        if re.match(r'^\s*\d+\s', stripped):
            data_idx = i
            break
    
    if data_idx is None:
        return {}
    
    # Split data row by whitespace
    data_line = lines[data_idx]
    fields = data_line.split()
    
    result = {}
    for name, idx in field_map.items():
        if idx < len(fields):
            result[name] = fields[idx]
        else:
            result[name] = ''
    
    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: vastai show instance ID | parse-vast-table.py FIELD [FIELD...]", file=sys.stderr)
        print("Fields: contract_id, status, machine_id, ssh_host, ssh_port, price, image", file=sys.stderr)
        sys.exit(1)
    
    lines = sys.stdin.readlines()
    if not lines:
        sys.exit(1)
    
    parsed = parse_table(lines)
    
    instance = parsed.get('instance', {})
    ssh = parsed.get('ssh', {})
    network = parsed.get('network', {})
    
    # Merge all sections
    all_fields = {}
    all_fields.update(instance)
    all_fields.update(ssh)
    all_fields.update(network)
    
    # Output requested fields
    values = []
    for field in sys.argv[1:]:
        val = all_fields.get(field, '')
        values.append(val)
    
    print(' '.join(values))


if __name__ == '__main__':
    main()
