import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import {
  makeCounterProvider,
  makeHistogramProvider,
} from '@willsoto/nestjs-prometheus';
import {
  HTTP_REQUEST_DURATION_SECONDS,
  HTTP_REQUESTS_TOTAL,
  HttpMetricsMiddleware,
} from './http-metrics.middleware';

const LABEL_NAMES = ['method', 'route', 'status_code'];

@Module({
  providers: [
    makeCounterProvider({
      name: HTTP_REQUESTS_TOTAL,
      help: 'Total number of HTTP requests',
      labelNames: LABEL_NAMES,
    }),
    makeHistogramProvider({
      name: HTTP_REQUEST_DURATION_SECONDS,
      help: 'HTTP request duration in seconds',
      labelNames: LABEL_NAMES,
      // 부하 테스트에서 P95/P99 는 100~500ms 구간에 놓이는데, histogram_quantile 은 버킷 안을 직선으로 보간하므로
      // 이 구간이 성기면 값이 크게 부정확해진다. 그래서 75/150/200/300/750ms 를 추가해 해상도를 높였다.
      // 가장 큰 유한 버킷을 넘는 값은 histogram_quantile 이 그 상한으로 뭉개 추정한다 — 비관적 락 경합으로
      // 지연이 수십 초까지 늘어지는 부하 테스트(#32)에서 10s 버킷이 그대로 상한처럼 찍히는 걸 확인해서
      // 15/30/60/120s 를 추가했다(#36). 60s는 k6 기본 요청 타임아웃과 같아 그 근처 분포를 구분하는 데 쓰인다.
      buckets: [
        0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.5, 0.75, 1, 2.5,
        5, 10, 15, 30, 60, 120,
      ],
    }),
    HttpMetricsMiddleware,
  ],
})
export class HttpMetricsModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    // Express 5 에서 '*path' 는 루트('/')를 매칭하지 못하므로 '{*path}' 로 선택적 와일드카드를 쓴다.
    // Prometheus 스크레이핑과 kubelet 헬스체크 요청은 부하 지표를 오염시키므로 제외한다.
    consumer
      .apply(HttpMetricsMiddleware)
      .exclude('metrics', 'health')
      .forRoutes('{*path}');
  }
}
