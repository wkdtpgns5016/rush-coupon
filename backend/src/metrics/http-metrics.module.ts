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
      // 선착순 발급처럼 수십 ms 단위 지연 변화를 봐야 하므로 기본 버킷보다 촘촘하게 둔다.
      buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    }),
    HttpMetricsMiddleware,
  ],
})
export class HttpMetricsModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    // Express 5 에서 '*path' 는 루트('/')를 매칭하지 못하므로 '{*path}' 로 선택적 와일드카드를 쓴다.
    // Prometheus 스크레이핑 요청 자체는 부하 지표를 오염시키므로 제외한다.
    consumer
      .apply(HttpMetricsMiddleware)
      .exclude('metrics')
      .forRoutes('{*path}');
  }
}
