"""Bounded Qwen 0.6B LoRA pilot using the official Qwen dataset layout.

Loss layout follows QwenLM/Qwen3-TTS finetuning/sft_12hz.py (Apache-2.0).
Base model stays frozen; only talker attention q/v adapters are updated.
"""
from pathlib import Path
import argparse
import gc
import json
import os
import random
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
TTS = ROOT / 'data/LocalTTS'
BASE = TTS / 'models/Qwen3-TTS-12Hz-0.6B-Base-pytorch'
os.environ.setdefault('HF_HOME', str(TTS / 'hf-cache/windows'))
sys.path.insert(0, str(Path(__file__).parent / 'vendor/qwen_finetuning'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dataset', type=Path, required=True)
    ap.add_argument('--steps', type=int, default=30)
    ap.add_argument('--lr', type=float, default=5e-5)
    args = ap.parse_args()
    if not 1 <= args.steps <= 500:
        raise ValueError('Use 1..500 optimizer steps per bounded run')
    import torch
    from qwen_tts import Qwen3TTSModel, Qwen3TTSTokenizer
    from peft import LoraConfig, get_peft_model
    from dataset import TTSDataset
    random.seed(42)
    torch.manual_seed(42)
    splits = {}
    tokenizer = None
    for name in ['train', 'validation']:
        cache = args.dataset / f'{name}.codes.jsonl'
        if cache.exists():
            rows = [json.loads(s) for s in cache.read_text(encoding='utf-8').splitlines() if s]
        else:
            rows = [json.loads(s) for s in (args.dataset/f'{name}.jsonl').read_text(encoding='utf-8').splitlines() if s]
            if tokenizer is None:
                tokenizer = Qwen3TTSTokenizer.from_pretrained(str(BASE/'speech_tokenizer'), device_map='cuda:0')
            for i, row in enumerate(rows):
                with torch.inference_mode():
                    result = tokenizer.encode(row['audio'])
                row['audio_codes'] = result.audio_codes[0].cpu().tolist()
                print(f'Encode {name} {i+1}/{len(rows)}', flush=True)
            cache.write_text('\n'.join(json.dumps(r, ensure_ascii=False) for r in rows)+'\n', encoding='utf-8')
        splits[name] = rows
    del tokenizer
    if 'result' in locals():
        del result
    gc.collect()
    torch.cuda.empty_cache()
    qwen = Qwen3TTSModel.from_pretrained(str(BASE), device_map='cuda:0',
        dtype=torch.bfloat16, attn_implementation='sdpa', local_files_only=True)
    qwen.model.requires_grad_(False)
    qwen.model.eval()
    talker = qwen.model.talker
    targets = [name for name, module in talker.named_modules()
               if name.startswith('model.layers.') and name.endswith(('.q_proj', '.v_proj'))]
    if not targets:
        raise RuntimeError('No attention adapter targets found')
    adapters = get_peft_model(talker, LoraConfig(r=8, lora_alpha=16,
        lora_dropout=0.05, target_modules=targets, bias='none'))
    qwen.model.talker = adapters
    params = [p for p in adapters.parameters() if p.requires_grad]
    before = [p.detach().cpu().clone() for p in params]
    print(f'Trainable parameters: {sum(p.numel() for p in params):,}', flush=True)
    train_data = TTSDataset(splits['train'], qwen.processor, qwen.model.config)
    val_data = TTSDataset(splits['validation'], qwen.processor, qwen.model.config)
    optimizer = torch.optim.AdamW(params, lr=args.lr, weight_decay=0.01)
    # Non-reentrant checkpointing supports frozen base embeddings with LoRA.
    talker.gradient_checkpointing_enable(gradient_checkpointing_kwargs={'use_reentrant': False})
    talker.config.use_cache = False

    def loss_for(data, index):
        batch = data.collate_fn([data[index]])
        batch = {k:v.to('cuda') for k,v in batch.items()}
        with torch.no_grad():
            speaker = qwen.model.speaker_encoder(batch['ref_mels'].to(torch.bfloat16)).detach()
            text = talker.text_projection(talker.model.text_embedding(batch['input_ids'][:,:,0]))
            text = text * batch['text_embedding_mask']
            codec = talker.model.codec_embedding(batch['input_ids'][:,:,1]) * batch['codec_embedding_mask']
            codec[:,6,:] = speaker
            embeddings = text + codec
            for i in range(1,16):
                embeddings += talker.code_predictor.get_input_embeddings()[i-1](batch['codec_ids'][:,:,i]) * batch['codec_mask'].unsqueeze(-1)
        with torch.autocast('cuda', dtype=torch.bfloat16):
            output = talker(inputs_embeds=embeddings[:,:-1,:], attention_mask=batch['attention_mask'][:,:-1],
                labels=batch['codec_0_labels'][:,1:], output_hidden_states=True, use_cache=False)
            hidden = output.hidden_states[0][-1][batch['codec_mask'][:,:-1]]
            _, subloss = talker.forward_sub_talker_finetune(batch['codec_ids'][batch['codec_mask']], hidden)
            return output.loss + 0.3*subloss

    def validate():
        talker.eval()
        with torch.no_grad():
            losses = [float(loss_for(val_data,i)) for i in range(min(6,len(val_data)))]
        return sum(losses)/len(losses)

    output = TTS/'windows/outputs'/('yachiyo-lora-'+time.strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True, exist_ok=False)
    start = time.perf_counter()
    baseline = validate()
    print(f'Validation before: {baseline:.4f}', flush=True)
    torch.cuda.reset_peak_memory_stats()
    order = list(range(len(train_data)))
    history = []
    for step in range(args.steps):
        talker.train()
        optimizer.zero_grad(set_to_none=True)
        total = 0.0
        for micro in range(2):
            pos = (step*2+micro) % len(order)
            if pos == 0:
                random.shuffle(order)
            loss = loss_for(train_data,order[pos])
            if not torch.isfinite(loss):
                raise RuntimeError('Nonfinite loss; base model remains untouched')
            (loss/2).backward()
            total += float(loss.detach())/2
        norm = torch.nn.utils.clip_grad_norm_(params,1.0)
        if not torch.isfinite(norm):
            raise RuntimeError('Nonfinite gradient')
        optimizer.step()
        row = {'step':step+1,'loss':total,'gradient_norm':float(norm)}
        history.append(row)
        with (output/'training.jsonl').open('a',encoding='utf-8') as log:
            log.write(json.dumps(row)+'\n')
        print(f'Step {step+1}/{args.steps}: loss={total:.4f} grad={float(norm):.4f}',flush=True)
        if (step+1)%10 == 0:
            adapters.save_pretrained(output/f'checkpoint-{step+1}')
    final_loss = validate()
    delta = sum(float((p.detach().cpu()-old).square().sum()) for p,old in zip(params,before))**0.5
    if delta == 0:
        raise RuntimeError('No adapter update detected')
    adapters.save_pretrained(output/'adapter')
    stats = {'dataset':str(args.dataset.resolve()),'base':str(BASE),
        'base_revision':json.loads((BASE/'download-revision.json').read_text())['revision'],
        'steps':args.steps,'lr':args.lr,'lora_rank':8,'gradient_accumulation':2,
        'trainable_parameters':sum(p.numel() for p in params),
        'validation_before':baseline,'validation_after':final_loss,'adapter_delta_l2':delta,
        'peak_allocated_mib':torch.cuda.max_memory_allocated()/1024**2,
        'peak_reserved_mib':torch.cuda.max_memory_reserved()/1024**2,
        'elapsed_seconds':time.perf_counter()-start,
        'quality_status':'Experimental pilot on automatic Japanese transcripts; Chinese quality and speaker likeness unverified.'}
    (output/'metrics.json').write_text(json.dumps(stats,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(stats,ensure_ascii=False,indent=2),flush=True)
    print(f'ADAPTER: {output / "adapter"}',flush=True)


if __name__ == '__main__':
    main()
