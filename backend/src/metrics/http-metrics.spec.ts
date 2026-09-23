import { Controller, Get, INestApplication, Param, Post } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { PrometheusModule } from '@willsoto/nestjs-prometheus';
import request from 'supertest';
import { App } from 'supertest/types';
import { HealthModule } from '../health/health.module';
import { HttpMetricsModule } from './http-metrics.module';

@Controller()
class StubRootController {
  @Get()
  hello() {
    return 'Hello World!';
  }
}

@Controller('coupons')
class StubCouponsController {
  @Post(':id/issue')
  issue(@Param('id') id: string) {
    return { id };
  }

  @Get(':id')
  findOne() {
    throw new Error('boom');
  }
}

describe('HTTP metrics', () => {
  let app: INestApplication<App>;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      imports: [
        PrometheusModule.register({
          defaultMetrics: { enabled: true },
          path: '/metrics',
        }),
        HttpMetricsModule,
        HealthModule,
      ],
      controllers: [StubRootController, StubCouponsController],
    }).compile();

    app = moduleRef.createNestApplication();
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  const scrape = async () =>
    (await request(app.getHttpServer()).get('/metrics').expect(200)).text;

  it('exposes default node metrics and both HTTP metrics in Prometheus text format', async () => {
    await request(app.getHttpServer()).post('/coupons/1/issue').expect(201);

    const text = await scrape();

    expect(text).toContain('# TYPE process_cpu_user_seconds_total counter');
    expect(text).toContain('# TYPE nodejs_eventloop_lag_seconds gauge');
    expect(text).toContain('# TYPE http_requests_total counter');
    expect(text).toContain('# TYPE http_request_duration_seconds histogram');
  });

  it('labels requests with the route template instead of the concrete path', async () => {
    await request(app.getHttpServer()).post('/coupons/42/issue').expect(201);
    await request(app.getHttpServer()).post('/coupons/43/issue').expect(201);

    const text = await scrape();

    expect(text).toMatch(
      /http_requests_total\{method="POST",route="\/coupons\/:id\/issue",status_code="201"\} [2-9]/,
    );
    expect(text).toContain(
      'http_request_duration_seconds_bucket{le="0.005",method="POST",route="/coupons/:id/issue",status_code="201"}',
    );
    expect(text).toContain(
      'http_request_duration_seconds_count{method="POST",route="/coupons/:id/issue",status_code="201"}',
    );
    expect(text).not.toContain('route="/coupons/42/issue"');
  });

  it('also counts requests to the root path', async () => {
    await request(app.getHttpServer()).get('/').expect(200);

    expect(await scrape()).toContain(
      'http_requests_total{method="GET",route="/",status_code="200"} 1',
    );
  });

  it('records the final status code for errors and collapses unknown paths', async () => {
    await request(app.getHttpServer()).get('/coupons/1').expect(500);
    await request(app.getHttpServer()).get('/no/such/path/123').expect(404);
    await request(app.getHttpServer()).get('/no/such/path/456').expect(404);

    const text = await scrape();

    expect(text).toContain(
      'http_requests_total{method="GET",route="/coupons/:id",status_code="500"} 1',
    );
    expect(text).toContain(
      'http_requests_total{method="GET",route="unmatched",status_code="404"} 2',
    );
    expect(text).not.toContain('/no/such/path');
  });

  it('does not count scrape requests to /metrics', async () => {
    await scrape();

    expect(await scrape()).not.toContain('route="/metrics"');
  });

  it('does not count health check requests to /health', async () => {
    await request(app.getHttpServer()).get('/health').expect(200);
    await request(app.getHttpServer()).get('/health').expect(200);

    expect(await scrape()).not.toContain('route="/health"');
  });

  it('uses fine-grained histogram buckets around 100-500ms for P95/P99 resolution', async () => {
    await request(app.getHttpServer()).get('/').expect(200);

    const text = await scrape();
    const bounds = [
      ...text.matchAll(
        /http_request_duration_seconds_bucket\{le="([^"]+)",method="GET",route="\/",status_code="200"\}/g,
      ),
    ].map((m) => m[1]);

    expect(bounds).toEqual([
      '0.005',
      '0.01',
      '0.025',
      '0.05',
      '0.075',
      '0.1',
      '0.15',
      '0.2',
      '0.3',
      '0.5',
      '0.75',
      '1',
      '2.5',
      '5',
      '10',
      '15',
      '30',
      '60',
      '120',
      '+Inf',
    ]);
  });
});
