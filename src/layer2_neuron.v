/*
 * Layer 2 Neuron - Single output neuron computation
 * 
 * Computes one neuron of Layer 2: 48 inputs → 1 output
 * 
 * Architecture:
 *   - 48 sequential MAC operations (reusing ternary_mac)
 *   - Add bias
 *   - NO activation (raw logit output)
 * 
 * Differences from Layer 1 Neuron:
 *   - 48 inputs (not 64) → 6-bit counter
 *   - Input is signed [1:0] (not unsigned)
 *   - Accumulator is 6-bit signed (not 7-bit)
 *   - Bias is 4-bit signed (same)
 *   - Output is 6-bit signed (not 7-bit)
 *   - NO activation function
 * 
 * Timing:
 *   - 48 clocks for MAC operations
 *   - 1 clock for bias addition
 *   - 1 clock for done signal
 *   - Total: 50 clocks per neuron
 */

module layer2_neuron (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,              // Start computation
    input  wire signed [1:0]  input_val,   // One input per clock (Layer 1 activation: -1 or +1)
    input  wire [1:0]  weight,             // One weight per clock (ternary encoding)
    input  wire signed [3:0]  bias,        // 4-bit bias (constant during computation)
    output reg         done,               // Computation complete
    output reg  signed [5:0]  result,      // 6-bit signed logit (no activation)
    output wire [5:0]  mac_count_out       // Current MAC index (for parent to provide correct input)
);

    // FSM states
    localparam IDLE     = 2'b00;
    localparam COMPUTE  = 2'b01;
    localparam ADD_BIAS = 2'b10;
    localparam DONE     = 2'b11;

    reg [1:0] state;
    reg [5:0] mac_count;  // Count 0-47 (48 MACs)
    
    // Expose mac_count to parent
    assign mac_count_out = mac_count;

    // MAC unit connections
    reg        mac_enable;
    
    // Handle signed inputs for Layer 2
    // Strategy: Convert signed input to magnitude + sign, then adjust weight accordingly
    // This allows us to use the same unsigned MAC unit as Layer 1
    // Example: (-1) × (-1) = |−1| × flip(-1) = 1 × (+1) = +1
    
    wire input_is_negative;
    wire [1:0] input_magnitude;
    wire [1:0] effective_weight;
    
    assign input_is_negative = input_val[1];  // MSB is sign bit in 2's complement
    assign input_magnitude = input_is_negative ? (~input_val + 1'b1) : input_val;  // abs(input_val)
    
    // Flip weight sign if input is negative: (-input) × weight = input × (-weight)
    assign effective_weight = input_is_negative ? 
        (weight == 2'b01 ? 2'b11 :  // +1 → -1
         weight == 2'b11 ? 2'b01 :  // -1 → +1
         2'b00) :                   // 0 → 0
        weight;
    
    // Instantiate ternary MAC
    // MAC has 7-bit accumulator - we'll use it directly
    wire signed [6:0] mac_acc_in;
    wire signed [6:0] mac_acc_out;
    
    ternary_mac mac (
        .clk(clk),
        .rst_n(rst_n),
        .enable(mac_enable),
        .input_val(input_magnitude),  // Pass magnitude
        .weight(effective_weight),    // Adjusted weight for sign
        .acc_in(mac_acc_in),
        .acc_out(mac_acc_out)
    );
    
    // Combinational feedback: feed MAC output back when accumulating
    // count=0: first MAC processes
    // count=1+: feed back previous results
    assign mac_acc_in = (state == COMPUTE && mac_count >= 6'd1) ? mac_acc_out : 7'sd0;

    // FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 0;
            result <= 6'sd0;
            mac_count <= 6'd0;
            mac_enable <= 0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 0;
                    mac_count <= 6'd0;
                    
                    if (start) begin
                        state <= COMPUTE;
                        mac_enable <= 1;  // Enable MAC one cycle early
                    end else begin
                        mac_enable <= 0;
                    end
                end

                COMPUTE: begin
                    // MAC is accumulating combinationally
                    if (mac_count == 6'd47) begin
                        // All 48 MACs complete
                        state <= ADD_BIAS;
                        mac_enable <= 0;
                    end else begin
                        mac_count <= mac_count + 1;
                    end
                end

                ADD_BIAS: begin
                    // Add bias to final accumulator value (truncate to 6-bit)
                    // Cast mac_acc_out to signed for proper signed addition
                    result <= $signed(mac_acc_out[5:0]) + $signed({{2{bias[3]}}, bias});  // Sign-extend 4-bit bias to 6-bit
                    state <= DONE;
                end

                DONE: begin
                    done <= 1;
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
