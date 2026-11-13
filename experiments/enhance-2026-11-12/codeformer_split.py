"""CodeFormer split into three LiteRT models for Android (Enhance step 1d, 2026-11-13).

The A069 GPU delegate computes CodeFormer's matrix products wrongly in several layouts (see codeformer_gpu.py), and
those products all sit in the 16x16 token transformer, about 2 % of the work. The split keeps them off the GPU:

  encoder  (GPU)  face [1, 3, 512, 512] -> lq [1, 256, 16, 16] + skip features at 32, 64, 128, 256 px
  middle   (CPU)  lq -> quantised features [1, 256, 16, 16]: the original transformer, topk and codebook lookup
  decoder  (GPU)  quantised features + skip features -> restored face [1, 3, 512, 512], fidelity w = 0.8

Encoder and decoder use the GPU-safe GroupNorm and AttnBlock from codeformer_gpu.py (same maths). The middle part is the
original code: only the codebook lookup is written as an embedding lookup (identical result) so LiteRT can convert it.
"""
import torch

from codeformer_gpu import adaptive_instance_normalization_safe

FIDELITY = 0.8
SKIP_SIZES = ("32", "64", "128", "256")


class Encoder(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, face):
        skip_blocks = {self.net.fuse_encoder_block[size]: size for size in SKIP_SIZES}
        skips = {}
        x = face
        for index, block in enumerate(self.net.encoder.blocks):
            x = block(x)
            if index in skip_blocks:
                skips[skip_blocks[index]] = x
        return (x,) + tuple(skips[size] for size in SKIP_SIZES)


class Middle(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, lq_feat):
        net = self.net
        pos_emb = net.position_emb.unsqueeze(1)
        query_emb = net.feat_emb(lq_feat.flatten(2).permute(2, 0, 1))
        for layer in net.ft_layers:
            query_emb = layer(query_emb, query_pos=pos_emb)
        logits = net.idx_pred_layer(query_emb).permute(1, 0, 2)
        top_idx = torch.topk(torch.softmax(logits, dim=2), 1, dim=2)[1]
        quant_feat = net.quantize.embedding(top_idx.view(-1)).view(1, 16, 16, 256).permute(0, 3, 1, 2)
        # AdaIN without basicsr's [b, c, hw] reshape: same maths; this part runs on the CPU, but one copy is simpler.
        return adaptive_instance_normalization_safe(quant_feat, lq_feat)


class Decoder(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, quant_feat, skip32, skip64, skip128, skip256):
        net = self.net
        skips = dict(zip(SKIP_SIZES, (skip32, skip64, skip128, skip256)))
        fuse_blocks = {net.fuse_generator_block[size]: size for size in SKIP_SIZES}
        x = quant_feat
        for index, block in enumerate(net.generator.blocks):
            x = block(x)
            if index in fuse_blocks:
                size = fuse_blocks[index]
                x = net.fuse_convs_dict[size](skips[size], x, FIDELITY)
        return x
