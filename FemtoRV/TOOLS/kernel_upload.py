#!/usr/bin/env python3
"""Upload a file to the RetroKernel's SD card via the 'load' command.

Usage: kernel_upload.py <local_file> <serial_port> <dest_path>
Example: kernel_upload.py args.bin /dev/ttyACM0 /bin/args.bin
"""

import serial
import sys
import time
import os

def xmodem_send(ser, filepath):
    """Send file using XMODEM protocol (checksum mode)."""
    SOH = 0x01
    EOT = 0x04
    ACK = 0x06
    NAK = 0x15

    data = open(filepath, 'rb').read()
    file_size = len(data)

    # Pad to 128-byte boundary
    if len(data) % 128 != 0:
        data += b'\x1a' * (128 - len(data) % 128)

    num_packets = len(data) // 128
    print(f"File size: {file_size} bytes ({num_packets} packets)")

    # Wait for NAK
    print("Waiting for NAK...", end='', flush=True)
    timeout = time.time() + 30
    while time.time() < timeout:
        b = ser.read(1)
        if b == bytes([NAK]):
            print(" got it")
            break
    else:
        print(" TIMEOUT")
        return False

    # Send packets
    pkt_num = 1
    for i in range(num_packets):
        chunk = data[i*128:(i+1)*128]

        # Build packet: SOH, pkt_num, ~pkt_num, 128 bytes, checksum
        checksum = sum(chunk) & 0xFF
        packet = bytes([SOH, pkt_num & 0xFF, (255 - pkt_num) & 0xFF]) + chunk + bytes([checksum])

        # Send and wait for ACK
        retries = 0
        while retries < 10:
            ser.write(packet)
            time.sleep(0.05)
            resp = ser.read(1)
            if resp == bytes([ACK]):
                break
            elif resp == bytes([NAK]):
                retries += 1
                print(f"\n  Retry pkt {pkt_num}", end='', flush=True)
            else:
                retries += 1
                time.sleep(0.1)
        else:
            print(f"\n  Failed on packet {pkt_num}")
            return False

        pkt_num = (pkt_num + 1) & 0xFF
        sent = min((i + 1) * 128, file_size)
        pct = sent * 100 // file_size
        print(f"\r  {sent}/{file_size} bytes ({pct}%)", end='', flush=True)

    # Send EOT
    ser.write(bytes([EOT]))
    time.sleep(0.1)
    resp = ser.read(1)
    if resp == bytes([ACK]):
        print("\nTransfer complete!")
        return True
    else:
        print(f"\nEOT response: {resp}")
        return False

def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <local_file> <serial_port> <dest_path>")
        sys.exit(1)

    local_file = sys.argv[1]
    port = sys.argv[2]
    dest_path = sys.argv[3]

    if not os.path.exists(local_file):
        print(f"File not found: {local_file}")
        sys.exit(1)

    ser = serial.Serial(port, 115200, timeout=2)
    time.sleep(0.5)
    ser.read(10000)  # Drain

    # Send load command
    cmd = f"load {dest_path}\r"
    print(f"Sending: load {dest_path}")
    for c in cmd:
        ser.write(c.encode())
        time.sleep(0.02)

    # Wait for XMODEM ready
    time.sleep(1)
    data = ser.read(5000)
    text = data.decode('ascii', errors='replace')
    print(f"Kernel: {text.strip()}")

    # Do XMODEM transfer
    ok = xmodem_send(ser, local_file)

    # Read result
    time.sleep(2)
    result = ser.read(5000)
    print(f"Result: {result.decode('ascii', errors='replace').strip()}")

    ser.close()
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
