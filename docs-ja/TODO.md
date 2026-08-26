# TODO

[English](../docs/TODO.md)

## P0 — Shell CLI の使い勝手と選択ポリシー

- [x] `models.json` を会計対象、`model-selection.json` を自動選択ポリシーとして分離する。
- [x] `check` / `select` の long/short option と互換位置引数を用意する。
- [x] `--model/-m`、`--estimated-tokens/-t`、`--quality/-q` を扱い、既定 quality は `low` とする。
- [x] 無料 quota group とモデル品質・タスク難易度を分離する。
- [ ] 旧位置引数形式を将来 Deprecated にするか判断する。

## P0 — `run` の E2E フロー

- [x] `run` を主たるユーザー向けコマンドとして追加する。
- [ ] `--input/-i` と stdin を扱う。現在は位置引数 prompt を扱う。
- [x] 通常推論用 `OPENAI_API_KEY` と Organization Usage 用 `OPENAI_ADMIN_KEY` を分離する。
- [ ] Organization Admin key の作成場所と管理用途限定であることを文書化する。
- [x] `POST /responses/input_tokens` で実際の request input token 数を取得し、旧 byte-based ローカル概算を廃止する。
- [x] `input_tokens + max_output_tokens` を推論前に予約する。
- [x] 予約量を収容できる候補を quota check してから推論する。
- [x] quota check 成功後にのみ Responses API を実行する。
- [x] `usage.input_tokens`、`usage.output_tokens`、`usage.total_tokens` を stderr の診断情報として表示する。
- [x] `--max-output-tokens/-o` と `--model/-m` を実装する。
- [ ] `--raw/-r` と `--input/-i` を実装する。
- [ ] tools、structured output、files/images、previous response 等をどこまで扱うか定義する。

## P0 — 年間プリペイド予算（次回開発の最優先）

- [ ] 現在の `run` 対応の次に最優先で着手する。
- [ ] 購入済み prepaid credit を日次無料 quota と別予算として扱う。
- [ ] 無料 quota を先に使い、収まらない場合のみ年間 `$5` 未満なら有料実行を許可し、今回の実行で上限を超えるなら BLOCK する。
- [ ] 年間上限を設定可能にし、既定値を `$5` とする。
- [ ] 最新 input/output 単価から事前見積し、actual usage が得られれば実績で会計する。
- [ ] 通常の有料 fallback は `low` 順を優先し、`high` は明示時のみ使う。
- [ ] 年間累計有料額の正本を決め、公式 API で確実に取れなければ推測せずローカル/明示会計を使う。
- [ ] 年間リセット境界と永続化形式を定義する。
- [ ] credit の1年失効は年間上限とは別に扱う。
- [ ] prepaid balance / expiry を公式 API で取得可能か調査し、Billing UI を runtime policy 用にスクレイピングしない。
- [ ] expiry を確実に取れる場合は optional な burn-down policy を設計する。
- [ ] prepaid credit があっても年間上限を暗黙に超えない。
- [ ] 複数 grant、異なる expiry、billing 遅延/negative balance の扱いを定義する。
- [ ] expiry を取得できなければユーザー明示設定を許可し、推測しない。

## P1 — 会計ロジックの実環境検証

- [x] Usage 0 の `status --raw` を実 Admin API key で検証し `results: []` を確認済み。
- [ ] 実推論後の Usage API record を確認する。
- [ ] `service_tier` で incentive 対象を確実に識別できるか判断する。
- [ ] 検証完了までは登録対象モデルの Usage をすべて消費として数える。
- [ ] secret/organization identifier を除去したレスポンス例を記録する。

## P1 — モデルポリシー保守

- [ ] audit 期限ごとに incentive 対象、quota group、availability/deprecation、pricing を再確認する。
- [ ] 自動選択候補を新モデルとの比較で再評価する。
- [ ] 自動選択から外した active model も会計レジストリには残す。
- [ ] 全候補が `models.json` に存在するテストを追加する。

## P1 — テスト

- [ ] Usage API mock を含む Shell テストを拡充する。
- [ ] UTC reset、tier、reserve、unknown model、quota 枯渇、fallback を網羅する。
- [ ] long/short alias と候補順をテストする。
- [x] 公式 input-token counting、`run` E2E、actual usage diagnostics の mock test を追加する。
- [ ] 年間有料予算の free-first / fallback / cap / reset / persistence / high をテストする。
- [ ] expiry/burn-down 実装時に境界テストを追加する。
- [ ] 将来の Python / Swift でも同じ policy fixture を使う。

## P2

- [ ] Python 3 で共通 policy と registry を実装する。
- [ ] Swift 6 Package で同じ policy を実装する。

## Design constraints

- 無料 quota を常に先に消費する。
- 有料 fallback は年間上限（既定 `$5`）で制限する。
- モデル選択のための推論 call は行わない。input-token counting は非推論の Responses API operation として扱う。
- quota group と quality/task difficulty を混同しない。
- 現行 OpenAI 一次資料と観測 API 挙動を stale な仮定より優先する。
- `spec/QUOTA_POLICY.md` を言語非依存の behavioral source of truth とする。
