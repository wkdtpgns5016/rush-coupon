import type { Config } from 'jest';
import { pathsToModuleNameMapper } from 'ts-jest';
import ts from 'typescript';

// Path aliases (e.g. the ones added by `nest g library`) live in tsconfig.json,
// so they are read from there instead of being duplicated here.
const { config: tsconfig } = ts.readConfigFile(
  './tsconfig.json',
  ts.sys.readFile,
);
const paths = tsconfig?.compilerOptions?.paths ?? {};

const config: Config = {
  moduleFileExtensions: ['js', 'json', 'ts'],
  rootDir: '.',
  testRegex: '.*\\.spec\\.ts$',
  transform: {
    '^.+\\.(t|j)s$': 'ts-jest',
  },
  moduleNameMapper: pathsToModuleNameMapper(paths, { prefix: '<rootDir>/' }),
  collectCoverageFrom: [
    'src/**/*.(t|j)s',
    'libs/**/*.(t|j)s',
    'apps/**/*.(t|j)s',
  ],
  coverageDirectory: './coverage',
  testEnvironment: 'node',
  // 여러 *.spec.ts가 같은 실제 Postgres/Valkey/RabbitMQ에 붙어 TRUNCATE·purge·consume를 수행한다.
  // 기본값(파일마다 별도 워커 프로세스, 병렬 실행)으로 돌리면 서로 다른 스펙이 같은 큐/테이블을
  // 동시에 건드려 레이스가 난다 — 워커 1개로 고정해 스펙 파일이 순차 실행되게 한다.
  maxWorkers: 1,
};

export default config;
