# TODO

[English](../docs/TODO.md)

## P0 — Shell CLI の使い勝手と選択ポリシー

- [x] `models.json` を広い会計レジストリ、`model-selection.json` を自動選択ポリシーとして分離する。
- [x] `check` / `select` の long/short option と互換位置引数を用意する。
- [x] `--model/-m`、`--estimated-tokens/-t`、`--quality/-q` を扱う。
- [x] prompt を持たない `select` の既定 quality は `low` のまま、`run` は prompt-aware な `auto` を既定にする。
- [x] 無料 quota group とモデル品質・タスク難易度を分離する。
- [x] 通常の無料 quota では Terra → Luna を優先する。
- [x] 旧位置引数形式は 0.x の間だけ互換維持し、option 形式を正規形として 1.0 で削除予定とする。

## P0 — `run` の自動 quality 判定

- [x] `run -q auto` を追加し、`run` の既定にする。prompt のない `select` の既定は変更しない。
- [x] 小さな Luna classifier で通常のモデル選択前に `low` / `high` だけを判定する。
- [x] 明示 `-q low` / `-q high` / `-m MODEL` を自動判定より優先し、classifier を呼ばない。
- [x] classifier 自身の `input_tokens + max_output_tokens` を無料 quota に予約してから dispatch する。
- [x] quality 判定だけのために有料 fallback は使わない。classifier が使えない、または不正出力なら設定済み `low` fallback を使う。
- [x] classifier と routing の診断を stderr に出す。
- [x] classifier model / effort / output cap / instructions / fallback を `model-selection.json` に置く。
- [x] auto→high と明示 override の bypass を mock test する。
- [ ] easy/hard の代表 prompt fixture を用意し、classifier model/prompt の変更前に精度評価できるようにする。

## P0 — `run` の E2E フロー

- [x] `run` を主たるユーザー向けコマンドとして追加する。
- [x] `--input/-i`、`--input -`、非 TTY stdin、位置引数 prompt を扱う。
- [x] 通常推論用 `OPENAI_API_KEY` と Organization Usage / Costs 用 `OPENAI_ADMIN_KEY` を分離する。
- [x] Organization Owner が Admin key を作る場所と管理用途を文書化する。
- [x] `POST /responses/input_tokens` で実 input token 数を取得する。
- [x] `input_tokens + max_output_tokens` を推論前に予約する。
- [x] 予約量を収容できる候補を quota check してから推論する。
- [x] quota/budget check 成功後にのみ Responses API を実行する。
- [x] actual usage を stderr に表示する。
- [x] `--max-output-tokens/-o`、`--model/-m`、`--raw/-r`、`--input/-i` を実装する。
- [x] `--effort/-e` で Responses API の `reasoning.effort` を指定し、モデル選択の `--quality/-q` とは分離する。
- [x] plain text + model/quality/effort/max-output/raw に限定し、tools / structured output / files/images / previous response / 任意 field は quota/cost semantics を定義するまで非対応とする。

## P0 — 年間プリペイド予算

- [x] 意図的な有料 fallback を日次無料 quota と別予算として扱う。
- [x] 無料 quota を先に使い、収まらない場合だけ UTC 暦年の年間予算を使う。既定 `$5`、今回の最悪ケース予約で上限を超えるなら BLOCK する。
- [x] 年間上限を設定可能にし、`0` で有料 fallback を無効化する。
- [x] current reviewed input/output 単価から事前見積し、actual usage 取得後に精算する。
- [x] 有料候補順を無料 quota と分離し、通常 `low` は Luna → Terra → Sol、明示 `high` は Sol-first とする。
- [x] 年初来の実支出の下限には公式 Organization Costs endpoint を使い、OpenAIQuotaFuse 外からの直接 API 利用も Costs 反映後は年間上限に含める。
- [x] 1月1日 00:00 UTC から Costs API をページングし、UTC 暦年全体の USD amount を集計する。
- [x] Costs 反映遅延に備え、直近の QuotaFuse 有料実行を local lag guard として保守的に加算する。結果不明の reservation は消さない。
- [x] `costs` / `costs --raw` で official spend、local guard、effective spend、raw Costs page を確認できるようにする。
- [x] credit の1年失効は年間上限とは別に扱う。
- [x] Billing UI はスクレイピングしない。prepaid balance + grant expiry の信頼できる runtime API は現時点では利用しない。
- [x] reliable な公式 expiry metadata が得られるまで burn-down policy は実装しない。
- [x] 推論 dispatch 前に最悪ケース費用を ledger に予約し、結果不明時は予約を残すことで年間上限を安全側に守る。
- [x] expiry を取得できない場合は推測しない。将来の明示設定は optional burn-down input としてのみ検討する。

## P1 — 会計ロジックの実環境検証

- [x] Usage 0 の `status --raw` を実 Admin API key で検証し `results: []` を確認済み。
- [ ] 実推論後の Usage API record を確認する。
- [ ] 実 Admin API key で `costs` を検証し、sanitize した年初来 Costs response を記録する。
- [ ] paid inference 後の Costs 反映遅延を観測し、現在の保守的な7日 local guard を縮められる根拠があるか確認する。
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

- [x] quota grouping/reserve、pricing、output extraction、paid-ledger guard の Python unit test を追加する。
- [x] input-token counting、input/stdin/raw、reasoning effort、自動 quality、明示 classifier bypass、Costs API spend、paid fallback、ledger completion、annual-cap blocking を mocked HTTP E2E で検証する。
- [x] PR と `main` push の CI で Python syntax、unit、mocked E2E、plugin manifest JSON validation を実行する。
- [x] Shell CI は wrapper smoke test のみにし、policy test は Python に一本化する。
- [ ] UTC reset、tier、reserve、unknown model、quota 枯渇、candidate fallback をさらに深く網羅する。
- [ ] long/short alias と候補順をテストする。
- [ ] annual reset、Costs pagination、legacy ledger migration、concurrent-process lock の境界テストを追加する。
- [ ] 将来の Swift 実装でも同じ policy fixture を再利用する。

## P1 — Python 3 実装

- [x] `models.json` と `model-selection.json` を共有し、`spec/QUOTA_POLICY.md` の主要 semantics を実装する。
- [x] Python 標準ライブラリで `run` / `status` / `costs` / `check` / `select` / `models` の有用な CLI semantics を揃える。
- [x] conservative reservation、auto-quality、reasoning effort、Organization Costs、年間 paid fallback、local lag guard を実装する。
- [x] Python を正規実装とし、旧 Shell 実装を薄い互換 wrapper に置き換える。
- [x] Python 実装に mocked HTTP E2E coverage を追加する。

## P1 — Codex プラグイン

- [x] `.codex-plugin/plugin.json` と bundled `quota-fuse` Skill を追加する。
- [x] plugin-facing かつ canonical execution surface は Python とし、Shell は Unix 互換 wrapper のみにする。
- [x] local marketplace install と credential setup を英日で文書化する。
- [x] plugin は Fuse 経由で dispatch された追加 API call を管理し、現在実行中の Codex turn の model を変更できないことを明記する。
- [x] plugin manifest JSON validation を CI に追加する。
- [ ] 安定した standalone Codex plugin validator が開発環境で利用可能になったら追加する。

## P2 — Swift 6 実装

- [ ] 同じ quota policy を実装する Swift Package を追加する。
- [ ] machine-readable registry を共有するか、strongly typed data を生成する。
- [ ] networking と policy logic を分離する。
- [ ] conservative reservation、auto-quality、reasoning effort、Organization Costs、annual paid budget を同じ semantics で実装する。

## Design constraints

- 無料 quota を常に先に試す。
- 有料 fallback は年間上限（既定 `$5` / UTC 暦年）で制限する。
- Organization Costs を実支出の下限とし、local accounting は reporting-delay window と結果不明 request の guard に使う。
- 無料 quota のモデル順は quota token あたりの能力、有料 fallback は年間ドル予算内の能力/コストを重視する。
- `run --quality auto` は、タスク難易度を判定するために別途 quota check 済みの無料推論を1回使ってよい。quality 選択だけのために有料予算は使わない。
- 明示 `--quality low/high` と `--model` は classifier を呼ばない。
- `--quality` はモデル選択順、`--effort` は選択されたモデル内の reasoning を制御する。
- quota group と quality/task difficulty を混同しない。
- 現行 OpenAI 一次資料と観測 API 挙動を stale な仮定より優先する。
- `spec/QUOTA_POLICY.md` を言語非依存の behavioral source of truth とする。
