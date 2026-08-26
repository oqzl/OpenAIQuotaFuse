# TODO

[English](../docs/TODO.md)

## P0 — Shell CLI の使い勝手と選択ポリシー

- [x] `models.json` を広い会計レジストリ、`model-selection.json` を自動選択ポリシーとして分離する。
- [x] `check` / `select` の long/short option と互換位置引数を用意する。
- [x] `--model/-m`、`--estimated-tokens/-t`、`--quality/-q` を扱い、既定 quality は `low` とする。
- [x] 無料 quota group とモデル品質・タスク難易度を分離する。
- [x] 通常の無料 quota では Terra → Luna を優先する。
- [x] 旧位置引数形式は 0.x の間だけ互換維持し、option 形式を正規形として 1.0 で削除予定とする。

## P0 — `run` の E2E フロー

- [x] `run` を主たるユーザー向けコマンドとして追加する。
- [x] `--input/-i`、`--input -`、非 TTY stdin、位置引数 prompt を扱う。
- [x] 通常推論用 `OPENAI_API_KEY` と Organization Usage 用 `OPENAI_ADMIN_KEY` を分離する。
- [x] Organization Owner が Admin key を作る場所と管理用途を文書化する。
- [x] `POST /responses/input_tokens` で実 input token 数を取得する。
- [x] `input_tokens + max_output_tokens` を推論前に予約する。
- [x] 予約量を収容できる候補を quota check してから推論する。
- [x] quota/budget check 成功後にのみ Responses API を実行する。
- [x] actual usage を stderr に表示する。
- [x] `--max-output-tokens/-o`、`--model/-m`、`--raw/-r`、`--input/-i` を実装する。
- [x] Shell P0 は plain text に限定し、tools / structured output / files/images / previous response / 任意 field は quota/cost semantics を定義するまで非対応とする。

## P0 — 年間プリペイド予算

- [x] 意図的な有料 fallback を日次無料 quota と別予算として扱う。
- [x] 無料 quota を先に使い、収まらない場合だけ UTC 暦年のローカル年間予算を使う。既定 `$5`、今回の最悪ケース予約で上限を超えるなら BLOCK する。
- [x] 年間上限を設定可能にし、`0` で有料 fallback を無効化する。
- [x] current reviewed input/output 単価から事前見積し、actual usage 取得後に精算する。
- [x] 有料候補順を無料 quota と分離し、通常 `low` は Luna → Terra → Sol、明示 `high` は Sol-first とする。
- [x] 年間累計の正本は明示的なローカル永続 ledger とし、OpenAI billing state を推測しない。
- [x] 年間リセット境界は 1月1日 00:00 UTC。reservation/reconciliation event を JSON に永続化する。
- [x] credit の1年失効は年間上限とは別に扱う。
- [x] Billing UI はスクレイピングしない。prepaid balance + grant expiry の信頼できる runtime API は現時点では利用しない。
- [x] reliable な公式 expiry metadata が得られるまで burn-down policy は実装しない。
- [x] 推論 dispatch 前に最悪ケース費用を ledger に予約し、結果不明時は予約を残すことで年間上限を安全側に守る。
- [x] 複数 grant / expiry / billing 遅延 / negative balance はローカル年間上限を変更しない。両会計を意図的に独立させる。
- [x] expiry を取得できない場合は推測しない。将来の明示設定は optional burn-down input としてのみ検討する。

## P1 — 会計ロジックの実環境検証

- [x] Usage 0 の `status --raw` を実 Admin API key で検証し `results: []` を確認済み。
- [ ] 実推論後の Usage API record を確認する。
- [ ] `service_tier` で incentive 対象を確実に識別できるか判断する。
- [ ] 検証完了までは登録対象モデルの Usage をすべて消費として数える。
- [ ] secret/organization identifier を除去したレスポンス例を記録する。

## P1 — モデルポリシー保守

- [ ] audit 期限ごとに incentive 対象、quota group、availability/deprecation、pricing を再確認する。
- [ ] 自動選択候補を新モデルとの比較で再評価する。
- [ ] 無料 quota と有料 fallback の候補順を別々に正当化する。
- [ ] 自動選択から外した active model も会計レジストリには残す。
- [ ] 全候補が `models.json` に存在するテストを追加する。

## P1 — テスト

- [ ] Usage API mock を含む Shell テストを拡充する。
- [ ] UTC reset、tier、reserve、unknown model、quota 枯渇、candidate fallback を網羅する。
- [ ] long/short alias と候補順をテストする。
- [x] input-token counting、input/stdin/raw、actual usage diagnostics の mock test を追加する。
- [x] annual paid budget の free-first / fallback / cap blocking / persistence / 基本的な paid order を mock test する。
- [ ] annual reset と concurrent-process lock の境界テストを追加する。
- [ ] 将来の Python / Swift でも同じ policy fixture を使う。

## P2

- [ ] Python 3 で共通 policy / registry / annual paid budget を実装する。
- [ ] Swift 6 Package で同じ policy を実装する。

## Design constraints

- 無料 quota を常に先に試す。
- 有料 fallback はローカル年間上限（既定 `$5` / UTC 暦年）で制限する。
- 無料 quota のモデル順は quota token あたりの能力、有料 fallback は年間ドル予算内の能力/コストを重視する。
- モデル選択のための推論 call は行わない。
- quota group と quality/task difficulty を混同しない。
- 現行 OpenAI 一次資料と観測 API 挙動を stale な仮定より優先する。
- `spec/QUOTA_POLICY.md` を言語非依存の behavioral source of truth とする。
