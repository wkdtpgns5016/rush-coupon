import { Controller, Get } from '@nestjs/common';

// Kubernetes readinessProbe 용. 프로세스가 요청에 응답할 수 있는지만 확인한다.
// DB 는 일부러 조회하지 않는다 — 부하로 커넥션 풀이 가득 찼을 때 프로브가 실패하면 Pod 가 트래픽에서 빠져 오히려 용량이 줄어든다.
@Controller('health')
export class HealthController {
  @Get()
  check() {
    return { status: 'ok' };
  }
}
