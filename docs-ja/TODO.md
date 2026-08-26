# TODO

[English](../docs/TODO.md)

この文書は、PR #1 で Shell MVP と共通 quota policy を整備した後に残った実装項目を管理する。

## P0 — Shell CLI の使い勝手と選択ポリシー

- [x] `models.json` は広い会計対象レジストリ、`model-selection.json` は絞り込んだ自動選択ポリシーとして分離する。
- [x] `check` と `select` に明示的な long option と short alias を追加し、既存の位置引数形式も互換性のため維持する。
- [x] Shell CLI で `--model/-m`、`--estimated-tokens/-t` を扱えるようにする。
- [x] 無料 quota group とモデル品質・タスク難易度の概念を分離する。quota group は容量・会計だけを表す。
- [x] 呼び出し側が明示できる task/quality hint として `--quality/-q` を追加し、既定 `low`、明示 `high` の選択 profile を quota group から分離する。モデル選択のための追加推論は行わない。
- [ ] 旧形式の `check MODEL TOKENS` と `select TOKENS [MODEL ...]` を将来 Deprecated にするか判断する。

## P0 — `run` の E2E フロー

- [x] 主たるユーザー向けコマンドとして `run` を追加する。
- [ ] 実際のリクエストを `--input/-i` で受け取り、パイプ利用向けに stdin も扱う。現在は位置引数の prompt を受け取る。
- [x] 通常推論用 `OPENAI_API_KEY` と Organization Usage API 用 `OPENAI_ADMIN_KEY` を分離する。
- [ ] `OPENAI_ADMIN_KEY` は OpenAI Platform の Organization の Admin Keys 画面で作成し、管理・Usage API 用だけに使うことを文書化する。
- [ ] `POST /responses/input_tokens` で input token 数を取得し、API が正本値を返せる場合はローカル推定を使わない。現在は入力 byte 数から安全側に概算する。
- [x] 現在のローカル input token 概算値に `max_output_tokens` を加え、推論前に保守的な必要 quota を予約する。
- [x] 保守的な予約量を収容できる quota group の最初の候補モデルを選ぶ。
- [x] quota check 成功後にのみ Responses API を実行する。
- [ ] 実レスポンスの `usage.input_tokens`、`usage.output_tokens`、`usage.total_tokens` を診断情報として公開する。
- [x] `run` に `--max-output-tokens/-o` と `--model/-m` を追加する。
- [ ] `run` に `--raw/-r` と `--input/-i` を追加する。
- [ ] tools、structured output、files/images、previous response 等をどこまで受けるか定義する。Shell リファレンス実装を汎用 API wrapper にしすぎない。

## P0 — 年間プリペイド予算（次回開発の最優先）

- [ ] 現在の `run` 対応の次に、最初のフォローアップとして着手する。
- [ ] API の購入済み prepaid credit を、日次無料 token quota とは別の予算として扱う。
- [ ] 既定ポリシーは「無料 quota を先に使う。無料 quota で収まらない場合のみ、年間の有料利用額が `$5` 未満なら有料実行を許可し、今回の実行で年間上限を超える場合は BLOCK」とする。
- [ ] 年間有料利用上限は明示的に設定可能にし、既定値は `$5` とする。無制限の有料フォールバックにはしない。
- [ ] 実行前に、選択モデルの最新 input/output 単価から今回の有料コストを見積もる。実行後に actual usage が得られた場合は実績値で会計する。
- [ ] 通常の有料フォールバックでは設定済みの `low` モデル順を優先し、年間予算を保守的に消費する。`high` は呼び出し側が明示した場合だけ使う。
- [ ] 年間累計有料額の正本を決める。公式 API から確実に取得できるならそれを優先し、無理なら推測せずローカルまたは明示設定による会計を使う。
- [ ] 年間リセット境界と永続化形式を定義し、CLI の起動ごとに累計が消えないようにする。
- [ ] 購入済み credit の失効管理は年間上限とは別に扱う。OpenAI の現行仕様では最低購入額は $5、購入済み credit は1年で失効する。
- [ ] prepaid credit の残高、個々の grant/購入の有効期限、またはそれらを確実に導出できる billing data を公式 API から取得できるか調査する。実行時ポリシーのために Billing UI をスクレイピングしない。
- [ ] 残高と有効期限を確実に取得できる場合、失効する credit を捨てる代わりに期限前に計画的に消費する optional な credit burn-down policy を設計する。
- [ ] prepaid credit が存在していても、設定済みの年間上限を暗黙に超えない。例外を許す場合は呼び出し側の明示指定を必須とする。
- [ ] 有効期限が異なる複数の credit grant/購入がある場合、および OpenAI が明記する billing 反映遅延・negative balance の可能性をどう扱うか定義する。
- [ ] 有効期限を公式 API から取得できない場合、推測せず、残 prepaid budget と expiry date をユーザー設定として明示的に与える方式を使えるようにする。

## P1 — 会計ロジックの実環境検証

- [x] 実 Admin API key で、Usage 0 のケースについて `status --raw` をライブ検証した。日次 bucket が期待通り `results: []` を返すことを確認済み。
- [ ] API billing を有効化した後、実推論を1回行い、その Usage API record を確認する。
- [ ] 実際の `service_tier` を確認し、Usage API だけで incentive 対象トラフィックを十分確実に識別できるか判断する。
- [ ] 検証が終わるまでは、登録済み対象モデルの Usage をすべて消費として数え、無料残量を過大評価しない。
- [ ] secret や organization identifier を除去した Usage API レスポンス例を記録する。

## P1 — モデルポリシー保守

- [ ] policy audit の期限切れごとに incentive 対象、quota group、availability/deprecation、API pricing を再確認する。
- [ ] 自動選択候補ごとに、同じ quota group の新モデルに対して残す理由がまだあるか評価する。
- [ ] 自動選択から外した古い active model も、対象である限り会計レジストリには残す。
- [ ] 全自動選択候補が `models.json` に存在することをテストする。
- [ ] 定期監査を実質的に改善する場合に限り、選択理由や単価メタデータの機械可読化を検討する。

## P1 — テスト

- [ ] Usage API レスポンスを mock した Shell テストを追加する。
- [ ] UTC 日次リセット、tier 1–2 / tier 3–5、reserve 計算、未知モデル、quota 枯渇、候補フォールバックを網羅する。
- [ ] long/short alias と明示的な候補順指定をテストする。
- [ ] 現在 README で既定経路としている `run` について、input-token counting と E2E の mock テストを追加する。
- [ ] 年間有料予算のテストを追加する。無料 quota 優先、上限未満での有料フォールバック、今回の実行で上限超過する場合の BLOCK、年間リセット、永続化、明示 `high` を含める。
- [ ] prepaid credit の expiry/burn-down を実装する場合、有効期限境界と billing metadata 取得不能時を含むテストを追加する。
- [ ] 将来の Python / Swift 実装でも同じ policy fixture を利用する。

## P2 — Python 3 実装

- [ ] `spec/QUOTA_POLICY.md` の言語非依存ポリシーを実装する。
- [ ] model/quota データを複製せず、`models.json` と `model-selection.json` を共有する。
- [ ] 有用な範囲で Shell と exit/error semantics を揃えつつ、Python API としては自然な形にする。
- [ ] 同じ保守的な `run` 予約方式を実装する。

## P2 — Swift 6 実装

- [ ] 同一 quota policy を実装する Swift Package を追加する。
- [ ] 機械可読レジストリを共有するか、そこから strongly typed data を生成する。
- [ ] networking と policy logic を分離し、各アプリが独自 UI を持てるようにする。
- [ ] 同じ保守的予約方式を実装する。

## 設計上の制約

- 無料 quota を常に先に使う。
- 有料フォールバックは設定済み年間上限で必ず制限する。既定は年 `$5`。
- モデル選択のためだけに推論を1回追加してはならない。
- 無料 quota group をモデル品質やタスク難易度の profile として表現しない。
- 最新の OpenAI 一次資料と実 API の観測結果を、古いリポジトリ上の仮定より優先する。
- 言語非依存の挙動は `spec/QUOTA_POLICY.md` を正本とする。
