#!/usr/bin/env python3
"""
XMODEM binary uploader for FemtoRV Monitor.

Usage:
    python3 xmodem_upload.py <binary_file> [port] [load_addr]

Examples:
    python3 xmodem_upload.py program.bin
    python3 xmodem_upload.py program.bin /dev/ttyACM0
    python3 xmodem_upload.py program.bin /dev/ttyACM0 10000

The script:
  1. Sends 'L <addr>' command to the monitor
  2. Waits for initial NAK (monitor ready)
  3. Sends file using XMODEM protocol (128-byte packets, 8-bit checksum)
  4. Optionally sends 'G <addr>' to execute the uploaded program
  5. With --follow, streams the program's serial output until Ctrl-C
"""

import serial
import time
import sys

SOH = 0x01
EOT = 0x04
ACK = 0x06
NAK = 0x15
CAN = 0x18

def send_packet(ser, packet_num, data, debug=False):
    """Send a single XMODEM packet, return True on ACK."""
    if len(data) < 128:
        data += b'\x00' * (128 - len(data))

    checksum = sum(data) & 0xFF
    complement = (255 - packet_num) & 0xFF
    packet = bytes([SOH, packet_num, complement]) + data + bytes([checksum])

    ser.write(packet)
    ser.flush()
    time.sleep(0.01)  # Allow USB CDC to flush final bytes

    # Wait for response
    start = time.time()
    while (time.time() - start) < 5.0:
        if ser.in_waiting:
            response = ser.read(1)[0]
            if debug:
                print(f"  [pkt {packet_num}] got 0x{response:02X}", end='')
            if response == ACK:
                if debug: print(" ACK")
                return True
            elif response == NAK:
                if debug: print(" NAK")
                return False
            elif response == CAN:
                print(" Transfer cancelled by receiver!")
                return False
            else:
                if debug: print(f" (ignoring)")
                # Ignore unexpected bytes and keep waiting
                continue
        time.sleep(0.005)

    print("Timeout waiting for ACK/NAK")
    return False

def upload(port, filename, load_addr=0x10000, execute=True, follow=False,
           idle_timeout=20):
    print(f"Port: {port}, File: {filename}")
    print(f"Load address: 0x{load_addr:08X}")

    ser = serial.Serial(port, 115200, timeout=1)
    time.sleep(0.5)
    ser.reset_input_buffer()

    # Send L command char by char (monitor reads char-at-a-time)
    cmd = f"L {load_addr:X}\r"
    print(f"Sending: {cmd.strip()}")
    for c in cmd:
        ser.write(c.encode())
        time.sleep(0.05)  # 50ms between chars - let monitor echo each one

    # Wait for NAK, consuming any text output along the way.
    # The monitor echoes the command and prints "Load to XXXXXXXX"
    # before sending NAK. The NAK (0x15) may arrive mixed with text.
    print("Waiting for NAK...")
    got_nak = False
    text_buf = bytearray()
    for _ in range(500):  # 5 seconds
        if ser.in_waiting:
            byte = ser.read(1)[0]
            if byte == NAK:
                print(f"Monitor: {text_buf.decode('ascii', errors='replace').strip()}")
                print("Got NAK - monitor ready for transfer")
                got_nak = True
                break
            else:
                text_buf.append(byte)
        time.sleep(0.01)

    if not got_nak:
        if text_buf:
            print(f"Monitor: {text_buf.decode('ascii', errors='replace').strip()}")
        print("ERROR: No NAK received. Is the monitor running?")
        ser.close()
        return False

    # Read file
    with open(filename, 'rb') as f:
        data = f.read()
    print(f"File size: {len(data)} bytes ({(len(data) + 127) // 128} packets)")

    # Send packets
    packet_num = 1
    offset = 0
    start_time = time.time()

    while offset < len(data):
        chunk = data[offset:offset+128]

        for attempt in range(10):
            if send_packet(ser, packet_num, chunk, debug=(packet_num <= 3)):
                packet_num = (packet_num + 1) & 0xFF
                offset += 128
                time.sleep(0.05)  # Let monitor finish processing before next packet
                # Progress
                pct = min(100, offset * 100 // len(data))
                print(f"\r  {offset}/{len(data)} bytes ({pct}%)", end='', flush=True)
                break
        else:
            print(f"\nFailed to send packet after 10 retries!")
            ser.close()
            return False

    print()

    # Send EOT
    ser.write(bytes([EOT]))
    time.sleep(0.5)
    if ser.in_waiting:
        resp = ser.read(1)[0]
        if resp != ACK:
            print(f"Warning: expected ACK to EOT, got 0x{resp:02X}")

    elapsed = time.time() - start_time
    print(f"Transfer complete in {elapsed:.1f}s ({len(data)/elapsed:.0f} bytes/sec)")

    # Read monitor response (wait for it to finish printing)
    time.sleep(1.0)
    if ser.in_waiting:
        msg = ser.read(ser.in_waiting).decode('ascii', errors='replace')
        print(f"Monitor: {msg.strip()}")

    # Wait for monitor prompt
    time.sleep(0.5)
    ser.reset_input_buffer()

    # Execute
    if execute:
        cmd = f"G {load_addr:X}\r"
        print(f"\nSending: {cmd.strip()}")
        for c in cmd:
            ser.write(c.encode())
            time.sleep(0.02)

        if follow:
            # Stream the program's output until Ctrl-C. Needed for anything
            # that runs longer than a moment -- a memory test or an SD
            # benchmark takes minutes, and the old fixed 1s peek below would
            # close the port long before the program printed its results.
            print(f"--- streaming output (Ctrl-C, or {idle_timeout}s idle, to stop) ---",
                  flush=True)
            last = time.time()
            try:
                while True:
                    n = ser.in_waiting
                    if n:
                        data = ser.read(n).decode('ascii', errors='replace')
                        sys.stdout.write(data)
                        sys.stdout.flush()
                        last = time.time()
                    else:
                        # Exit on a quiet line rather than blocking forever.
                        # An unattended --follow that never returns leaves an
                        # orphan holding the serial port; a second uploader
                        # then fights it for bytes, producing NAKs and
                        # pathological transfer rates that look like a board
                        # fault but are not.
                        if idle_timeout and (time.time() - last) > idle_timeout:
                            print(f"\n--- idle {idle_timeout}s, stopping ---")
                            break
                        time.sleep(0.02)
            except KeyboardInterrupt:
                print("\n--- stopped ---")
        else:
            time.sleep(1.0)
            if ser.in_waiting:
                msg = ser.read(ser.in_waiting).decode('ascii', errors='replace')
                print(f"Monitor: {msg.strip()}")

    ser.close()
    return True

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: xmodem_upload.py <binary_file> [port] [load_addr_hex]")
        print("  Default port: /dev/ttyACM0")
        print("  Default load address: 0x4000")
        sys.exit(1)

    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    follow = any(a in ('--follow', '-f') for a in sys.argv[1:])

    if not args:
        print("Usage: xmodem_upload.py <binary_file> [port] [load_addr_hex] [--follow]")
        sys.exit(1)

    filename = args[0]
    port = args[1] if len(args) > 1 else '/dev/ttyACM0'
    addr = int(args[2], 16) if len(args) > 2 else 0x4000

    idle = 20
    for a in sys.argv[1:]:
        if a.startswith('--idle='):
            idle = int(a.split('=', 1)[1])

    success = upload(port, filename, addr, execute=True, follow=follow,
                     idle_timeout=idle)
    sys.exit(0 if success else 1)
