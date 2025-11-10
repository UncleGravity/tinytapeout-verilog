/*
 * MNIST Top Module - Complete inference pipeline (ROM-based architecture)
 * 
 * Clean, self-contained design with all weights stored in layer ROMs.
 * Top module just manages pixel buffering and data flow between layers.
 * 
 * Input: 64 pixels (8×8 image), 2-bit quantized, streamed 4 pixels/cycle
 * Output: Digit prediction (0-9)
 * 
 * Processing Flow:
 *   1. IDLE → wait for start signal
 *   2. LOAD_PIXELS → store 64 pixels (16 cycles, 4 pixels/cycle)
 *   3. LAYER1 → compute all 48 neurons (~3,216 cycles)
 *   4. LAYER2 → compute all 10 neurons (~520 cycles)
 *   5. ARGMAX → read 10 logits and find maximum (11 cycles)
 *   6. DONE → output prediction
 *
 * Total: ~3,763 cycles per inference (16 + 3216 + 520 + 11)
 * 
 * Memory:
 *   - Layer 1 ROM: 804 bytes (inside layer1_full)
 *   - Layer 2 ROM: 133 bytes (inside layer2_full)
 *   - Pixel buffer: 16 bytes (64 × 2-bit)
 *   - Total: ~953 bytes
 */

module mnist_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,              // Start inference (pulse high)
    input  wire [7:0]  pixels_in,          // 4 pixels per cycle: [7:6]=px3, [5:4]=px2, [3:2]=px1, [1:0]=px0
    output reg         done,               // Inference complete
    output reg  [3:0]  prediction,         // Predicted digit (0-9)
    output reg         busy                // Computing (optional status flag)
);

    // ========================================================================
    // FSM States
    // ========================================================================
    localparam IDLE        = 3'b000;
    localparam LOAD_PIXELS = 3'b001;
    localparam LAYER1      = 3'b010;
    localparam LAYER2      = 3'b011;
    localparam ARGMAX      = 3'b100;
    localparam DONE_ST     = 3'b101;

    reg [2:0] state;
    reg [5:0] pixel_idx;           // Pixel counter (0-60, increments by 4) for loading
    reg [3:0] argmax_read_idx;     // Logit counter for argmax (0-9)
    
    // ========================================================================
    // Pixel Storage
    // ========================================================================
    // Store 64 pixels: 64 × 2 bits = 128 bits (16 bytes)
    reg [1:0] pixels [0:63];
    
    // ========================================================================
    // Layer 1: 64 inputs → 48 outputs (with sign activation)
    // ========================================================================
    reg layer1_start;
    wire layer1_done;
    wire layer1_busy;
    
    // Layer1 output storage for Layer2 to read
    reg signed [1:0] layer1_outputs [0:47];
    
    // Temporary read interface (for connecting to layer1_full's read ports)
    reg [5:0] layer1_read_addr;
    wire signed [1:0] layer1_read_data;
    
    // Pack pixels into flat vector for layer1_full
    wire [127:0] pixels_flat;
    genvar gp;
    generate
        for (gp = 0; gp < 64; gp = gp + 1) begin : pack_pixels
            assign pixels_flat[gp*2 +: 2] = pixels[gp];
        end
    endgenerate
    
    layer1_full layer1 (
        .clk(clk),
        .rst_n(rst_n),
        .start(layer1_start),
        .pixels_flat(pixels_flat),             // Pass flattened pixel vector
        .done(layer1_done),
        .busy(layer1_busy),
        .read_addr(layer1_read_addr),
        .read_data(layer1_read_data)
    );
    
    // ========================================================================
    // Layer 2: 48 inputs → 10 outputs (no activation, raw logits)
    // ========================================================================
    reg layer2_start;
    wire layer2_done;
    wire layer2_busy;
    wire signed [5:0] layer2_read_data;
    
    // Pack layer1 outputs into flat vector for layer2_full
    wire [95:0] layer1_outputs_flat;
    genvar ga;
    generate
        for (ga = 0; ga < 48; ga = ga + 1) begin : pack_activations
            assign layer1_outputs_flat[ga*2 +: 2] = layer1_outputs[ga];
        end
    endgenerate
    
    layer2_full layer2 (
        .clk(clk),
        .rst_n(rst_n),
        .start(layer2_start),
        .layer1_activations_flat(layer1_outputs_flat),  // Pass flattened activation vector
        .done(layer2_done),
        .busy(layer2_busy),
        .read_addr(argmax_read_idx),           // For reading logits for argmax
        .read_data(layer2_read_data)
    );
    
    // ========================================================================
    // Argmax: Find maximum logit
    // ========================================================================
    // Store all 10 logits for argmax
    reg signed [5:0] logits [0:9];
    wire [3:0] argmax_result;
    
    argmax argmax_inst (
        .logit_0(logits[0]),
        .logit_1(logits[1]),
        .logit_2(logits[2]),
        .logit_3(logits[3]),
        .logit_4(logits[4]),
        .logit_5(logits[5]),
        .logit_6(logits[6]),
        .logit_7(logits[7]),
        .logit_8(logits[8]),
        .logit_9(logits[9]),
        .max_index(argmax_result)
    );
    
    // ========================================================================
    // Main FSM
    // ========================================================================
    integer i;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 0;
            busy <= 0;
            prediction <= 0;
            pixel_idx <= 0;
            argmax_read_idx <= 0;
            layer1_read_addr <= 0;
            layer1_start <= 0;
            layer2_start <= 0;
            
            // Initialize logits
            for (i = 0; i < 10; i = i + 1) begin
                logits[i] <= 0;
            end
        end else begin
            case (state)
                // ============================================================
                IDLE: begin
                    done <= 0;
                    busy <= 0;
                    pixel_idx <= 0;
                    layer1_start <= 0;
                    layer2_start <= 0;
                    
                    if (start) begin
                        state <= LOAD_PIXELS;
                        busy <= 1;
                    end
                end
                
                // ============================================================
                LOAD_PIXELS: begin
                    // Store 4 incoming pixels per cycle
                    pixels[pixel_idx + 0] <= pixels_in[1:0];  // px0
                    pixels[pixel_idx + 1] <= pixels_in[3:2];  // px1
                    pixels[pixel_idx + 2] <= pixels_in[5:4];  // px2
                    pixels[pixel_idx + 3] <= pixels_in[7:6];  // px3
                    
                    if (pixel_idx == 6'd60) begin
                        // Just loaded pixels 60-63 (last 4), all 64 pixels done
                        state <= LAYER1;
                        layer1_start <= 1;
                    end else begin
                        pixel_idx <= pixel_idx + 4;
                    end
                end
                
                // ============================================================
                LAYER1: begin
                    layer1_start <= 0;  // Clear after 1 cycle
                    
                    // Layer1 reads pixels directly from array - no management needed!
                    
                    if (layer1_done) begin
                        // Layer 1 complete, copy outputs to array for Layer 2
                        state <= LAYER2;
                        layer1_read_addr <= 0;
                    end
                end
                
                // ============================================================
                LAYER2: begin
                    // First, copy all Layer1 outputs to array (48 cycles)
                    if (layer1_read_addr < 6'd48) begin
                        layer1_outputs[layer1_read_addr] <= layer1_read_data;
                        layer1_read_addr <= layer1_read_addr + 1;
                        
                        // Start Layer2 after copying first activation
                        if (layer1_read_addr == 6'd0) begin
                            layer2_start <= 1;
                        end else begin
                            layer2_start <= 0;
                        end
                    end else begin
                        layer2_start <= 0;
                    end
                    
                    // Layer2 reads activations directly from array - no management needed!
                    
                    if (layer2_done) begin
                        // Layer 2 complete, read logits for argmax
                        state <= ARGMAX;
                        argmax_read_idx <= 0;
                    end
                end
                
                // ============================================================
                ARGMAX: begin
                    // Read all 10 logits sequentially
                    if (argmax_read_idx <= 4'd9) begin
                        logits[argmax_read_idx] <= layer2_read_data;
                        argmax_read_idx <= argmax_read_idx + 1;
                    end
                    
                    if (argmax_read_idx == 4'd10) begin
                        // All logits read, argmax result is ready
                        prediction <= argmax_result;
                        state <= DONE_ST;
                        done <= 1;
                        busy <= 0;
                    end
                end
                
                // ============================================================
                DONE_ST: begin
                    // Hold done until start goes low
                    if (!start) begin
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
