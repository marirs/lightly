"""Enhance step 1d: CodeFormer cut after each stage, to find which stage gives NaN on the A069 GPU delegate.
Writes tflite/probes/<stage>.tflite. Run: .venv/bin/python convert_gpu_probes.py <stage>[+attn]   (+attn: with codeformer_gpu.attention_block_4d)
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "repos" / "CodeFormer"))

import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from basicsr.utils.registry import ARCH_REGISTRY  # noqa: E402
import basicsr.archs.codeformer_arch  # noqa: E402,F401
from basicsr.archs.codeformer_arch import adaptive_instance_normalization  # noqa: E402

import codeformer_gpu  # noqa: E402

torch.nn.GroupNorm.forward = codeformer_gpu.group_norm_without_big_reshape


class Probe(torch.nn.Module):
    def __init__(self, net, stage):
        super().__init__()
        self.net, self.stage = net, stage

    def forward(self, x):
        net = self.net
        if self.stage == "groupnorm":  # first conv + one reshape-free GroupNorm at 512x512
            return net.encoder.blocks[1].norm1(net.encoder.blocks[0](x))
        if self.stage in ("attn-norm", "attn-scores", "attn-qk"):  # inside encoder block 17 (first attention)
            for block in net.encoder.blocks[:17]:
                x = block(x)
            attention = net.encoder.blocks[17]
            normalised = attention.norm(x)
            if self.stage == "attn-norm":
                return normalised
            q, k = attention.q(normalised), attention.k(normalised)
            b, c, h, w = q.shape
            raw = torch.matmul(q.reshape(b, 1, c, h * w).transpose(2, 3), k.reshape(b, 1, c, h * w)) * (c ** -0.5)
            return raw if self.stage == "attn-qk" else torch.softmax(raw, dim=3)
        if self.stage.startswith("av-"):  # scores x v variants inside encoder block 17
            for block in net.encoder.blocks[:17]:
                x = block(x)
            attention = net.encoder.blocks[17]
            normalised = attention.norm(x)
            q, k, v = attention.q(normalised), attention.k(normalised), attention.v(normalised)
            b, c, h, w = q.shape

            def rows(tensor):
                return tensor.permute(0, 2, 3, 1).reshape(b, 1, h * w, c)

            scores = torch.softmax(torch.matmul(rows(q), rows(k).transpose(2, 3)) * (c ** -0.5), dim=3)
            if self.stage == "av-1":   # scores @ v rows, no transpose
                return torch.matmul(scores, rows(v))
            # av-2: same product in the A @ B^T form that q.k uses, B = v channels-first
            return torch.matmul(scores, v.reshape(b, 1, c, h * w).transpose(2, 3))
        if self.stage.startswith("qk-"):  # q.k variants inside encoder block 17
            for block in net.encoder.blocks[:17]:
                x = block(x)
            attention = net.encoder.blocks[17]
            normalised = attention.norm(x)
            q, k = attention.q(normalised), attention.k(normalised)
            b, c, h, w = q.shape
            q_rows = q.permute(0, 2, 3, 1).reshape(b, 1, h * w, c)   # channels-last rows, no transpose of q
            k_rows = k.permute(0, 2, 3, 1).reshape(b, 1, h * w, c)
            chunk = {"qk-A": c, "qk-D": 128, "qk-E": 64}[self.stage]
            raw = sum(torch.matmul(q_rows[..., i:i + chunk], k_rows[..., i:i + chunk].transpose(2, 3))
                      for i in range(0, c, chunk))
            return raw * (c ** -0.5)
        if self.stage.startswith("enc"):  # "enc<N>": encoder blocks 0..N
            for block in net.encoder.blocks[: int(self.stage[3:]) + 1]:
                x = block(x)
            return x
        for block in net.encoder.blocks:
            x = block(x)
        if self.stage == "encoder":  # all blocks
            return x
        pos_emb = net.position_emb.unsqueeze(1)
        query = net.feat_emb(x.flatten(2).permute(2, 0, 1))
        for layer in net.ft_layers:
            query = layer(query, query_pos=pos_emb)
        logits = net.idx_pred_layer(query).permute(1, 0, 2)
        if self.stage == "transformer":
            return logits
        weights = F.softmax((logits - logits.amax(dim=2, keepdim=True)) * codeformer_gpu.SHARPEN, dim=2)
        quant = torch.matmul(weights, net.quantize.embedding.weight).view(1, 16, 16, 256).permute(0, 3, 1, 2)
        return adaptive_instance_normalization(quant, x)  # stage "codebook"


def main(stage: str) -> None:
    import litert_torch
    file_name = stage
    if stage.endswith("+attn"):  # "...+attn": with the GPU-safe attention block
        from basicsr.archs.vqgan_arch import AttnBlock
        AttnBlock.forward = codeformer_gpu.attention_block_4d
        stage = stage[: -len("+attn")]
    net = ARCH_REGISTRY.get("CodeFormer")(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                                          connect_list=["32", "64", "128", "256"])
    net.load_state_dict(torch.load(HERE / "weights/codeformer/codeformer.pth", map_location="cpu",
                                   weights_only=False)["params_ema"])
    out = HERE / "tflite" / "probes"
    out.mkdir(parents=True, exist_ok=True)
    litert_torch.convert(Probe(net.eval(), stage).eval(), (torch.rand(1, 3, 512, 512) * 2 - 1,)).export(
        str(out / f"{file_name}.tflite"))
    print("saved", file_name, flush=True)


if __name__ == "__main__":
    main(sys.argv[1])
