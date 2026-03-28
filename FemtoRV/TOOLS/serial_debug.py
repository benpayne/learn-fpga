#!/usr/bin/env python3
"""Debug serial communication with FemtoRV Monitor - step by step"""

import serial
import time
import sys

port = sys.argv[1] if len(sys.argv) > 1 else '/dev/ttyACM0'
baud = 115200

print(f"Opening {port} at {baud}...")
try:
    ser = serial.Serial(port, baud, timeout=0.5)
except serial.SerialException as e:
    print(f"ERROR: {e}")
    if "busy" in str(e).lower():
        print("Another program has the port open (screen? minicom?). Close it first.")
    elif "permission" in str(e).lower():
        print("Permission denied. Add user to plugdev/dialout group or use sudo.")
    sys.exit(1)

time.sleep(1.0)  # Wait for device to settle after open
ser.reset_input_buffer()
ser.reset_output_buffer()

def read_all(timeout=1.0):
    """Read all available bytes with timeout, return as bytes"""
    result = bytearray()
    deadline = time.time() + timeout
    while time.time() < deadline:
        if ser.in_waiting:
            chunk = ser.read(ser.in_waiting)
            result.extend(chunk)
            deadline = time.time() + 0.2  # Reset timeout on data
        else:
            time.sleep(0.01)
    return bytes(result)

def show_bytes(data, label=""):
    """Display bytes as both text and hex"""
    if not data:
        print(f"  {label}(no data)")
        return
    # Text view (replace non-printable)
    text = ""
    for b in data:
        if 32 <= b < 127:
            text += chr(b)
        elif b == 13:
            text += "\\r"
        elif b == 10:
            text += "\\n"
        elif b == 0x15:
            text += "[NAK]"
        elif b == 0x06:
            text += "[ACK]"
        else:
            text += f"[{b:02X}]"
    print(f"  {label}{len(data)} bytes: {text}")

# =========================================================
print("\n=== Test 1: Send CR, wait for prompt ===")
ser.write(b'\r')
resp = read_all(1.5)
show_bytes(resp, "Response: ")

# =========================================================
print("\n=== Test 2: Send 'H' + CR, wait for help text ===")
ser.reset_input_buffer()
time.sleep(0.1)
ser.write(b'H')
time.sleep(0.1)  # Let echo come back
ser.write(b'\r')
resp = read_all(2.0)
show_bytes(resp, "Response: ")

# =========================================================
print("\n=== Test 3: Send 'M' + CR, wait for memory info ===")
ser.reset_input_buffer()
time.sleep(0.1)
ser.write(b'M')
time.sleep(0.1)
ser.write(b'\r')
resp = read_all(2.0)
show_bytes(resp, "Response: ")

# =========================================================
print("\n=== Test 4: Send 'L 4000' + CR, look for NAK byte ===")
ser.reset_input_buffer()
time.sleep(0.1)
ser.write(b'L')
time.sleep(0.05)
ser.write(b' ')
time.sleep(0.05)
ser.write(b'4')
time.sleep(0.05)
ser.write(b'0')
time.sleep(0.05)
ser.write(b'0')
time.sleep(0.05)
ser.write(b'0')
time.sleep(0.05)
ser.write(b'\r')

# Read byte by byte looking for NAK
print("  Reading responses (5 second timeout)...")
start = time.time()
all_bytes = bytearray()
found_nak = False
while (time.time() - start) < 5.0:
    if ser.in_waiting:
        b = ser.read(1)[0]
        all_bytes.append(b)
        if b == 0x15:
            print(f"  >>> NAK found at byte {len(all_bytes)}! XMODEM ready.")
            found_nak = True
            break
    time.sleep(0.005)

show_bytes(bytes(all_bytes), "All bytes: ")
if not found_nak:
    print("  >>> No NAK received")

# Cancel XMODEM if it started
ser.write(b'\x18\x18\x18')  # CAN CAN CAN
time.sleep(0.5)
ser.reset_input_buffer()

ser.close()
print("\nDone.")
