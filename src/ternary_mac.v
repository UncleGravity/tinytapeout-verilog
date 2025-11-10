/*
 * Ternary MAC (Multiply-Accumulate) Unit
 * 
 * Computes: acc_out = acc_in + (input_val * weight)
 * 
 * Where:
 *   - input_val: 2-bit unsigned [0-3]
 *   - weight: 2-bit ternary encoded as:
 *       00 = 0 (zero)
 *       01 = +1 (positive one)
 *       11 = -1 (negative one)
 *       10 = unused (treated as 0)
 *   - acc_in/out: 7-bit signed (enough for layer 1: [-39, 42])
 * 
 * This is the core computation unit - everything else is built on this.
 */

module ternary_mac (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,           // Perform MAC when high
    input  wire [1:0]  input_val,        // 2-bit input [0-3]
    input  wire [1:0]  weight,           // 2-bit ternary
    input  wire signed [6:0] acc_in,     // Accumulator input
    output reg  signed [6:0] acc_out     // Accumulator output
);

    // Ternary multiplication result (signed)
    reg signed [2:0] product;
    
    // Decode ternary weight and compute product
    // Zero-extend input_val from 2-bit to 3-bit (works for unsigned [0-3])
    wire signed [2:0] input_extended;
    assign input_extended = {1'b0, input_val}; // Zero-extend
    
    always @(*) begin
        case (weight)
            2'b00:   product = 3'sd0;              // weight = 0
            2'b01:   product = input_extended;     // weight = +1, product = input
            2'b11:   product = -input_extended;    // weight = -1, product = -input
            default: product = 3'sd0;              // Unused, treat as 0
        endcase
    end
    
    // Accumulate on clock edge when enabled
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= 7'sd0;
        end else if (enable) begin
            acc_out <= acc_in + $signed({{4{product[2]}}, product});  // Sign-extend 3-bit to 7-bit
        end
    end

endmodule
