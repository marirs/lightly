"""GPU-safe CodeFormer for LiteRT's GPU delegate (Enhance step 1d, 2026-11-13). Conversion-time only; same maths.

On the Nothing A069 (Adreno 710) the original CodeFormer graph ran only partly on the GPU (30 s per face), and the
first GPU-friendly attempts produced wrong or all-NaN output. Each replacement here was found by cutting the model into
stages and comparing the GPU (fp32) with the phone's CPU on a real face (convert_gpu_probes.py, phone/EnhanceBench.kt):

- codebook pick: softmax -> topk -> embedding lookup (TOPK_V2 / EMBEDDING_LOOKUP are not on the GPU) becomes a sharpened
  softmax times the codebook. Weights are one-hot except at near-ties, where two almost equally likely codes blend;
  check_gpu_codebook.py measures it against the original (0.1-0.45 of 255 on 22 real faces).
- GroupNorm: no reshape of full-size activations, scaled into fp16 range, staged spatial means.
- attention (VQGAN AttnBlock and the transformer's multi-head attention): the delegate computed products of the forms
  reshape-then-transpose @ B and A @ B wrongly (errors as large as the values). Every product here is A @ B^T on
  channels-last [1, 1, tokens, channels] rows, or a fully connected layer when B is a constant.

What the result uses (codeformer_split.py): group_norm_without_big_reshape, attention_block_4d and
adaptive_instance_normalization_safe, in the encoder and decoder that run on the GPU. Superseded, kept for the record:
forward_gpu_friendly and transformer_layer_rows (one single GPU model). The converter turned the transformer's products
into fully connected layers with non-constant weights, which the delegate rejects (1,303 of 3,426 ops on the GPU), and
the output still differed from the CPU by up to 1.34 on [-1, 1]. The split runs the transformer on the CPU instead.
Not for Core ML: the GroupNorm rewrite made the iPhones slower and its fp16 output wrong (26-41 of 255).
"""
import torch
import torch.nn.functional as F

# Logit gaps between the first and second code are measured in check_gpu_codebook.py; at this factor a gap of 0.1
# already gives the winner > 99.99 % of the weight.
SHARPEN = 100.0


def rows(image):
    """[b, c, h, w] -> channels-last token rows [b, 1, h*w, c] (how LiteRT already stores the activation)."""
    b, c, h, w = image.shape
    return image.permute(0, 2, 3, 1).reshape(b, 1, h * w, c)


def image_from_rows(token_rows, h, w):
    b, _, _, c = token_rows.shape
    return token_rows.reshape(b, h, w, c).permute(0, 3, 1, 2)


def transformer_layer_rows(layer, tokens, position):
    """TransformerSALayer.forward on [1, 1, hw, c] rows (original: (hw, b, c) through nn.MultiheadAttention)."""
    attention = layer.self_attn
    heads, channels = attention.num_heads, attention.embed_dim
    head_dim = channels // heads
    w_q, w_k, w_v = attention.in_proj_weight.chunk(3)
    b_q, b_k, b_v = attention.in_proj_bias.chunk(3)

    normalised = layer.norm1(tokens)
    query_key = normalised + position
    q = F.linear(query_key, w_q, b_q)
    k = F.linear(query_key, w_k, b_k)
    head_outputs = []
    for head in range(heads):
        part = slice(head * head_dim, (head + 1) * head_dim)
        scores = torch.softmax(torch.matmul(q[..., part], k[..., part].transpose(2, 3)) * head_dim ** -0.5, dim=3)
        # v^T for this head as constant @ rows^T ([1, 1, d, hw]), so the next product is scores @ (v^T)^T: A @ B^T.
        v_t = torch.matmul(w_v[part].reshape(1, 1, head_dim, channels), normalised.transpose(2, 3)) \
            + b_v[part].reshape(1, 1, head_dim, 1)
        head_outputs.append(torch.matmul(scores, v_t.transpose(2, 3)))
    attended = F.linear(torch.cat(head_outputs, dim=3), attention.out_proj.weight, attention.out_proj.bias)
    tokens = tokens + attended
    return tokens + layer.linear2(layer.activation(layer.linear1(layer.norm2(tokens))))


def adaptive_instance_normalization_safe(content, style, eps=1e-5):
    """basicsr's adaptive_instance_normalization (unbiased variance, eps 1e-5) without its [b, c, hw] reshape."""
    def mean_std(feature):
        mean = staged_spatial_mean(feature)
        count = feature.shape[2] * feature.shape[3]
        variance = staged_spatial_mean((feature - mean) * (feature - mean)) * (count / (count - 1))
        return mean, torch.sqrt(variance + eps)

    style_mean, style_std = mean_std(style)
    content_mean, content_std = mean_std(content)
    return (content - content_mean) / content_std * style_std + style_mean


def forward_gpu_friendly(self, x, w=0.0, adain=True):
    """Inference-only copy of CodeFormer.forward (repos/CodeFormer b33cc7d) with the GPU-safe pieces above."""
    enc_feat_dict = {}
    out_list = [self.fuse_encoder_block[f_size] for f_size in self.connect_list]
    for i, block in enumerate(self.encoder.blocks):
        x = block(x)
        if i in out_list:
            enc_feat_dict[str(int(x.shape[-1]))] = x.clone()
    lq_feat = x

    position = self.position_emb.reshape(1, 1, -1, self.position_emb.shape[-1])
    tokens = self.feat_emb(rows(lq_feat))
    for layer in self.ft_layers:
        tokens = transformer_layer_rows(layer, tokens, position)
    logits = self.idx_pred_layer(tokens)                       # [1, 1, hw, codebook size]

    # Original: softmax -> topk(1) -> lookup. Same argmax; subtracting the max keeps fp16 GPU math in range.
    weights = F.softmax((logits - logits.amax(dim=3, keepdim=True)) * SHARPEN, dim=3)
    codebook = self.quantize.embedding.weight                  # [codebook size, 256]
    quant_feat = image_from_rows(F.linear(weights, codebook.t()), 16, 16)   # fully connected: weights @ codebook
    if adain:
        quant_feat = adaptive_instance_normalization_safe(quant_feat, lq_feat)

    x = quant_feat
    fuse_list = [self.fuse_generator_block[f_size] for f_size in self.connect_list]
    for i, block in enumerate(self.generator.blocks):
        x = block(x)
        if i in fuse_list:
            f_size = str(int(x.shape[-1]))
            if w > 0:
                x = self.fuse_convs_dict[f_size](enc_feat_dict[f_size].detach(), x, w)
    return x, logits.reshape(1, -1, logits.shape[-1])


def group_norm_without_big_reshape(self, x):
    """Drop-in GroupNorm.forward, same maths, for conversion only (step 1d).

    PyTorch's GroupNorm reshapes the whole activation to [N, groups, C/groups, H*W]; LiteRT keeps that as RESHAPE +
    TRANSPOSE pairs on 512x512x64 tensors, which the GPU pays for in layout conversions. Groups are equal-sized, so the
    group mean is the mean of the per-channel spatial means: only [N, C, 1, 1] tensors are reshaped here.
    """
    batch, channels = x.shape[0], x.shape[1]
    groups = self.num_groups

    # Block-averaging matrix: channel i's output is the mean over its group. A constant FULLY_CONNECTED on [N, C]
    # stats; `expand` would become BROADCAST_TO, which the GPU delegate rejects (544 of 2,236 ops delegated, 32 s).
    group_of = torch.arange(channels) // (channels // groups)
    averaging = ((group_of[:, None] == group_of[None, :]).float() / (channels // groups)).to(x.dtype)

    def per_group(channel_stat):
        # The matrix is symmetric, so linear (x @ A.T) is x @ A; linear lowers to FULLY_CONNECTED.
        return torch.nn.functional.linear(channel_stat.reshape(batch, channels), averaging).reshape(batch, channels, 1, 1)

    # fp16 range (GPU delegate, precision loss allowed): decoder activations reach ~39,000 on real faces, so their
    # squares overflow 65,504 and every output became NaN on the A069. GroupNorm does not depend on the input's scale
    # once eps is scaled with it: GN(x) = (x/s - mean) * rsqrt(var(x/s) + eps/s^2). Dividing by the tensor's largest
    # magnitude keeps every intermediate within [-2, 4].
    scale = x.abs().amax(dim=(2, 3), keepdim=True).amax(dim=1, keepdim=True).clamp(min=1e-4)
    scaled = x / scale
    centred = scaled - per_group(staged_spatial_mean(scaled))
    variance = per_group(staged_spatial_mean(centred * centred))
    # Floor: in fp16, eps/s^2 underflows to 0 for large s, and a constant group would then give rsqrt(0).
    normalised = centred * torch.rsqrt((variance + self.eps / (scale * scale)).clamp(min=1e-7))
    if self.affine:
        normalised = normalised * self.weight.view(1, channels, 1, 1) + self.bias.view(1, channels, 1, 1)
    return normalised


def staged_spatial_mean(tensor):
    """Spatial mean as 8x8 average pools, then a mean over at most 8x8 values: no single reduction adds more than 64
    terms, so an fp16 accumulator cannot overflow (one MEAN over 512x512 adds 262,144). Same value as
    tensor.mean(dim=(2, 3), keepdim=True) for power-of-two sizes, which every CodeFormer GroupNorm input has."""
    while tensor.shape[-1] > 8:
        tensor = torch.nn.functional.avg_pool2d(tensor, kernel_size=8)
    return tensor.mean(dim=(2, 3), keepdim=True)


def attention_block_4d(self, x):
    """Drop-in vqgan_arch.AttnBlock.forward, same maths, for conversion only (step 1d).

    The original flattens q to [b, c, hw] and transposes it for torch.bmm. On the A069 GPU delegate that
    reshape-then-transpose gave garbage (q.k off by 9 on values up to 8.9, fp32, encoder block 17), and so did a rank-4
    copy of it. Rows taken channels-last ([b, 1, hw, c], which is how LiteRT already stores the activation) give the
    CPU result to 1e-5. Each probe was checked on the A069 GPU (fp32) against its CPU: convert_gpu_probes.py.
    """
    h_ = self.norm(x)
    q, k, v = self.q(h_), self.k(h_), self.v(h_)
    b, c, h, w = q.shape

    def rows(tensor):
        return tensor.permute(0, 2, 3, 1).reshape(b, 1, h * w, c)    # [b, 1, hw, c]

    scores = torch.softmax(torch.matmul(rows(q), rows(k).transpose(2, 3)) * (int(c) ** (-0.5)), dim=3)
    # Both products in the A @ B^T form: scores @ rows(v) (no transpose) was off by 4.2 on values up to 4.0 on the
    # A069 GPU; scores @ (v channels-first)^T matches the CPU to 7e-6.
    attended = torch.matmul(scores, v.reshape(b, 1, c, h * w).transpose(2, 3))   # [b, 1, hw(query), c]
    return x + self.proj_out(attended.reshape(b, h, w, c).permute(0, 3, 1, 2))
