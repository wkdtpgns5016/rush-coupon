import { Injectable, NestMiddleware } from '@nestjs/common';
import { InjectMetric } from '@willsoto/nestjs-prometheus';
import type { NextFunction, Request, Response } from 'express';
import type { Counter, Histogram } from 'prom-client';

export const HTTP_REQUESTS_TOTAL = 'http_requests_total';
export const HTTP_REQUEST_DURATION_SECONDS = 'http_request_duration_seconds';

// 라우트에 매칭되지 않은 요청(404, CORS preflight 등)은 URL 그대로 라벨에 넣으면
// 카디널리티가 무한히 늘어나므로 고정 값으로 묶는다.
const UNMATCHED_ROUTE = 'unmatched';

@Injectable()
export class HttpMetricsMiddleware implements NestMiddleware {
  constructor(
    @InjectMetric(HTTP_REQUESTS_TOTAL)
    private readonly requestsTotal: Counter<string>,
    @InjectMetric(HTTP_REQUEST_DURATION_SECONDS)
    private readonly requestDuration: Histogram<string>,
  ) {}

  use(req: Request, res: Response, next: NextFunction) {
    const startedAt = process.hrtime.bigint();

    // req.route 는 라우터가 매칭된 뒤에 채워지므로 응답이 끝나는 시점에 읽는다.
    res.on('finish', () => {
      const labels = {
        method: req.method,
        route: this.resolveRoute(req),
        status_code: res.statusCode,
      };
      const seconds = Number(process.hrtime.bigint() - startedAt) / 1e9;

      this.requestsTotal.inc(labels);
      this.requestDuration.observe(labels, seconds);
    });

    next();
  }

  private resolveRoute(req: Request): string {
    const path: unknown = req.route?.path;
    return typeof path === 'string' ? `${req.baseUrl}${path}` : UNMATCHED_ROUTE;
  }
}
