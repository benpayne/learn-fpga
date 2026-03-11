// PS2 decoder for FemtoRV
//  PS2Decoder.v
//
// Ben Payne, 2024
//
// This file simply includes the ps2-controller-lib FemtoRV wrapper
// The library provides the complete implementation with proper parameterization

`ifndef PS2_DECODER_DEVICE_V
`define PS2_DECODER_DEVICE_V

`ifdef SYNTHESIS
// For synthesis, include the library wrapper which includes all dependencies
`include "lib/ps2-controller-lib/wrappers/fpga/ps2_femtorv_wrapper.v"
`else
// For simulation, may need different path
`include "lib/ps2-controller-lib/wrappers/fpga/ps2_femtorv_wrapper.v"
`endif

`endif // PS2_DECODER_DEVICE_V
