/*
 * Layer 2 Full - Complete second layer with integrated ROM
 * 
 * Self-contained module that processes all 10 output neurons sequentially.
 * Weights and biases are stored in internal ROM (loaded from hex files).
 * 
 * Input: 48 signed activations from Layer 1 (streamed cyclically by parent)
 * Output: 10 signed 6-bit logits stored internally, readable after done
 * 
 * Architecture:
 *   - Internal ROM: W2 weights (480 entries) + b2 biases (10 entries)
 *   - Reuses 1 layer2_neuron for all 10 outputs
 *   - FSM manages sequential processing and ROM addressing
 * 
 * Memory:
 *   - W2: 480 weights × 2 bits = 960 bits
 *   - b2: 10 biases × 4 bits = 40 bits
 *   - Output buffer: 10 × 6 bits = 60 bits
 *   - Total: 1,060 bits (133 bytes)
 * 
 * Timing:
 *   - Each neuron: ~52 cycles (48 MACs + bias + overhead)
 *   - Total: ~520 cycles for all 10 neurons
 */

module layer2_full (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,              // Start Layer 2 computation
    input  wire [95:0] layer1_activations_flat, // All 48 Layer 1 outputs as flat vector (48 × 2-bit = 96 bits)
    output reg         done,               // Computation complete
    output reg         busy,               // Currently computing
    // Read interface for outputs (after done=1)
    input  wire [3:0]  read_addr,          // Which output to read (0-9)
    output wire signed [5:0] read_data     // Logit value at read_addr
);

    // ========================================================================
    // Unpack flat activation vector into array
    // ========================================================================
    reg signed [1:0] layer1_activations [0:47];
    integer k;
    always @(*) begin
        for (k = 0; k < 48; k = k + 1) begin
            layer1_activations[k] = layer1_activations_flat[k*2 +: 2];
        end
    end

    // ========================================================================
    // Weight and Bias ROM
    // ========================================================================
    
    // Layer 2 Weight ROM: 480 weights (10 neurons × 48 inputs)
    // Column-major: neuron N weights at addresses [N*48, N*48+47]
    reg [1:0] w2_rom [0:479];
    
    // Layer 2 Bias ROM: 10 biases
    reg [3:0] b2_rom [0:9];
    
    initial begin
        `include "layer2_rom_init.vh"
    end
    
    // ========================================================================
    // FSM States
    // ========================================================================
    localparam IDLE    = 2'b00;
    localparam COMPUTE = 2'b01;
    localparam STORE   = 2'b10;
    localparam DONE_ST = 2'b11;

    reg [1:0] state;
    reg [3:0] neuron_idx;     // Current neuron (0-9)
    
    // ========================================================================
    // Output Storage
    // ========================================================================
    // Store 10 logits: 10 × 6 bits = 60 bits
    reg signed [5:0] output_mem [0:9];
    
    // Output read interface - combinational
    assign read_data = output_mem[read_addr];
    
    // ========================================================================
    // Neuron Computation
    // ========================================================================
    reg neuron_start;
    wire neuron_done;
    wire signed [5:0] neuron_result;
    wire [5:0] neuron_mac_count;  // From neuron module
    
    // ROM addressing for current neuron - use neuron's counter!
    wire [8:0] weight_addr = neuron_idx * 9'd48 + {3'd0, neuron_mac_count};
    wire [1:0] current_weight = w2_rom[weight_addr];
    wire signed [3:0] current_bias = $signed(b2_rom[neuron_idx]);
    
    // Read layer1 activation directly from array using neuron's MAC count
    wire signed [1:0] current_activation = layer1_activations[neuron_mac_count];
    
    layer2_neuron neuron (
        .clk(clk),
        .rst_n(rst_n),
        .start(neuron_start),
        .input_val(current_activation),  // Read directly from layer1 array
        .weight(current_weight),
        .bias(current_bias),
        .done(neuron_done),
        .result(neuron_result),
        .mac_count_out(neuron_mac_count)
    );
    
    // ========================================================================
    // FSM and Control
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            neuron_idx <= 4'd0;
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
                        neuron_idx <= 4'd0;
                        state <= COMPUTE;
                        neuron_start <= 1'b1;  // Start first neuron
                        busy <= 1'b1;
                    end
                end
                
                COMPUTE: begin
                    neuron_start <= 1'b0;  // Clear start after one cycle
                    
                    // No counter management - neuron tracks its own MAC count!
                    
                    if (neuron_done) begin
                        // Store result
                        output_mem[neuron_idx] <= neuron_result;
                        state <= STORE;
                    end
                end
                
                STORE: begin
                    // Check if more neurons to process
                    if (neuron_idx < 4'd9) begin
                        neuron_idx <= neuron_idx + 1;
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
