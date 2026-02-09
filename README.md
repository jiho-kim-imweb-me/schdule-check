# Jiho's Dashboard

개인 일정/작업 상태를 팀원들에게 단일 링크로 공유하는 실시간 대시보드.

## Architecture

```
Claude CLI (여러 인스턴스)
    │
    ├── GitHub Contents API ──> data/status.json ──> GitHub Pages (뷰어)
    │
    └── Notion API ──────────> Notion Database ──────> (장기 히스토리)
```

## Quick Start

### 대시보드 보기

브라우저에서 GitHub Pages URL로 접속하면 30초마다 자동 갱신됩니다.

### 상태 업데이트

```bash
# 작업 추가
./scripts/update-status.sh add --id task-001 --title "RDS 슬로우쿼리 분석" --category analysis

# 상태 업데이트
./scripts/update-status.sh update --id task-001 --status in_progress --progress 30 --note "TOP 20 쿼리 분석중"

# 완료 처리
./scripts/update-status.sh done --id task-001

# 일정 추가
./scripts/update-status.sh schedule --time "15:00" --label "인시던트 리뷰"

# 작업 삭제
./scripts/update-status.sh remove --id task-001

# Notion 미러링 포함
./scripts/update-status.sh update --id task-001 --status done --notion
```

## Status Values

| 상태 | 설명 |
|------|------|
| `waiting` | 대기중 |
| `in_progress` | 진행중 |
| `done` | 완료 |
| `blocked` | 차단됨 |

## Categories

| 카테고리 | 이모지 | 설명 |
|----------|--------|------|
| `analysis` | 📊 | 분석 |
| `infra` | ⚙️ | 인프라 |
| `incident` | 🔴 | 장애 |
| `cost` | 💰 | 비용 |
| `security` | 🔒 | 보안 |
| `automation` | 🤖 | 자동화 |
| `monitoring` | 📡 | 모니터링 |
| `docs` | 📝 | 문서화 |

## Tech Stack

- **Frontend**: HTML + Tailwind CSS CDN (빌드 불필요)
- **Data**: JSON (GitHub Contents API로 업데이트)
- **Hosting**: GitHub Pages
- **Mirroring**: Notion Database
