/*
 * Layer 1 Full - Complete first layer with integrated ROM
 * 
 * Self-contained module that processes all 48 neurons sequentially.
 * Weights and biases are stored in internal ROM (loaded from hex files).
 * 
 * Input: 64-pixel array reference (no cyclical management needed)
 * Output: 48 activated values stored internally, readable after done
 * 
 * Architecture:
 *   - Internal ROM: W1 weights (3,072 entries) + b1 biases (48 entries)
 *   - Reuses 1 layer1_neuron module for all 48 neurons
 *   - Reuses 1 sign_activation module
 *   - FSM manages sequential processing and ROM addressing
 *   - Reads pixels directly from input array using mac_count as index
 * 
 * Memory:
 *   - W1: 3,072 weights × 2 bits = 6,144 bits
 *   - b1: 48 biases × 4 bits = 192 bits
 *   - Output buffer: 48 × 2 bits = 96 bits
 *   - Total: 6,432 bits (804 bytes)
 * 
 * Timing:
 *   - Each neuron: ~67 cycles (64 MACs + bias + overhead)
 *   - Total: ~3,216 cycles for all 48 neurons
 */

module layer1_full (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,              // Start layer 1 computation
    input  wire [127:0] pixels_flat,       // Input pixels as flat vector (64 × 2-bit = 128 bits)
    output reg         done,               // Computation complete
    output reg         busy,               // Currently computing
    // Read interface for outputs (after done=1)
    input  wire [5:0]  read_addr,          // Which output to read (0-47)
    output wire signed [1:0] read_data     // Output value at read_addr
);

    // ========================================================================
    // Unpack flat pixel vector into array
    // ========================================================================
    reg [1:0] pixels [0:63];
    integer k;
    always @(*) begin
        for (k = 0; k < 64; k = k + 1) begin
            pixels[k] = pixels_flat[k*2 +: 2];
        end
    end

    // ========================================================================
    // Weight and Bias ROM
    // ========================================================================
    
    // Layer 1 Weight ROM: 3,072 weights (48 neurons × 64 inputs)
    // Column-major: neuron N weights at addresses [N*64, N*64+63]
    reg [1:0] w1_rom [0:3071];
    
    // Layer 1 Bias ROM: 48 biases
    reg [3:0] b1_rom [0:47];
    
    initial begin
        `include "layer1_rom_init.vh"
    end
    
    // ========================================================================
    // FSM States
    // ========================================================================
    localparam IDLE    = 2'b00;
    localparam COMPUTE = 2'b01;
    localparam STORE   = 2'b10;
    localparam DONE_ST = 2'b11;

    reg [1:0] state;
    reg [5:0] neuron_idx;              // Current neuron (0-47)
    
    // ========================================================================
    // Output Storage
    // ========================================================================
    // Store 48 activated outputs: 48 × 2 bits = 96 bits
    reg signed [1:0] output_mem [0:47];
    
    // Output read interface - combinational
    assign read_data = output_mem[read_addr];
    
    // ========================================================================
    // Neuron Computation
    // ========================================================================
    reg neuron_start;
    wire neuron_done;
    wire signed [6:0] neuron_result;
    wire [5:0] neuron_mac_count;       // Which MAC the neuron is on
    
    // ROM addressing for current neuron - use neuron's counter
    wire [11:0] weight_addr = neuron_idx * 12'd64 + {6'd0, neuron_mac_count};
    wire [1:0] current_weight = w1_rom[weight_addr];
    wire signed [3:0] current_bias = $signed(b1_rom[neuron_idx]);
    
    // Read pixel directly from array using neuron's MAC count
    wire [1:0] current_pixel = pixels[neuron_mac_count];
    
    layer1_neuron neuron (
        .clk(clk),
        .rst_n(rst_n),
        .start(neuron_start),
        .input_val(current_pixel),       // Read directly from pixel array
        .weight(current_weight),
        .bias(current_bias),
        .done(neuron_done),
        .result(neuron_result),
        .mac_count_out(neuron_mac_count) // Get neuron's MAC counter
    );
    
    // ========================================================================
    // Activation
    // ========================================================================
    wire signed [1:0] activated_result;
    
    sign_activation activation (
        .in_val(neuron_result),
        .out(activated_result)
    );
    
    // ========================================================================
    // FSM and Control
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            neuron_idx <= 6'd0;
            neuron_start <= 1'b0;
            done <= 1'b0;
            busy <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    busy <= 1'b0;
                    neuron_start <= 1'b0;
                    
                    if (start) begin
                        neuron_idx <= 6'd0;
                        state <= COMPUTE;
                        neuron_start <= 1'b1;  // Start first neuron
                        busy <= 1'b1;
                    end
                end
                
                COMPUTE: begin
                    neuron_start <= 1'b0;  // Clear start after one cycle
                    
                    // No counter management needed - neuron tracks its own MAC count!
                    
                    if (neuron_done) begin
                        // Store activated result
                        output_mem[neuron_idx] <= activated_result;
                        state <= STORE;
                    end
                end
                
                STORE: begin
                    // Check if more neurons to process
                    if (neuron_idx < 6'd47) begin
                        neuron_idx <= neuron_idx + 1'b1;
                        state <= COMPUTE;
                        neuron_start <= 1'b1;  // Start next neuron
                    end else begin
                        // All neurons done
                        state <= DONE_ST;
                        done <= 1'b1;
                        busy <= 1'b0;
                    end
                end
                
                DONE_ST: begin
                    // Stay in DONE until start goes low
                    if (!start) begin
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
