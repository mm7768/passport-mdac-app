-- Storage existence metadata and provider responses are test doubles; no blob or Azure HTTP is used.
begin;
insert into mdac_retry_app_20261027.ocr_batches(id,uploaded_by,source_type,file_path,status)
values('b1000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111','IMAGE','ISOLATED/fixture.jpg','UPLOADED');
commit;

begin;
set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select set_config('request.headers','{"x-mdac-protocol":"2"}',true);
do $$ declare b mdac_retry_app_20261027.ocr_batches; old_token uuid; payload jsonb; begin
 select * into b from mdac_retry_app_20261027.claim_ocr_batch('ISOLATED-ocr-retry',900,5,'b1000000-0000-4000-8000-000000000001');
 if b.attempt_count<>1 then raise exception 'OCR initial claim failed'; end if;
 old_token:=b.claim_token;
 perform set_config('request.headers',jsonb_build_object('x-mdac-protocol','2','x-mdac-batch-token',b.claim_token)::text,true);
 perform mdac_retry_app_20261027.heartbeat_ocr_v2('ISOLATED-ocr-retry',b.id,'BUSY','ISOLATED','retry-test');
 perform mdac_retry_app_20261027.release_unstarted_ocr_batch_v2('ISOLATED-ocr-retry',b.id);
 if not exists(select 1 from mdac_retry_app_20261027.ocr_batches where id=b.id and status::text='UPLOADED' and attempt_count=1 and claim_token is null) then raise exception 'Pre-provider recovery lost history'; end if;
 select * into b from mdac_retry_app_20261027.claim_ocr_batch('ISOLATED-ocr-retry',900,5,b.id);
 if b.attempt_count<>2 or b.claim_token=old_token then raise exception 'OCR did not rotate claim'; end if;
 begin
  perform mdac_retry_app_20261027.heartbeat_ocr_v2('ISOLATED-ocr-retry',b.id,'BUSY','ISOLATED','retry-test');
  raise exception 'Old OCR token accepted';
 exception when insufficient_privilege then null;
 end;
 perform set_config('request.headers',jsonb_build_object('x-mdac-protocol','2','x-mdac-batch-token',b.claim_token)::text,true);
 perform mdac_retry_app_20261027.heartbeat_ocr_v2('ISOLATED-ocr-retry',b.id,'BUSY','ISOLATED','retry-test');
 perform mdac_retry_app_20261027.before_ocr_analyze_v2('ISOLATED-ocr-retry',b.id);
 perform mdac_retry_app_20261027.record_ocr_operation_v2('ISOLATED-ocr-retry',b.id,'https://isolated.invalid/operation/1');
 begin
  perform mdac_retry_app_20261027.release_unstarted_ocr_batch_v2('ISOLATED-ocr-retry',b.id);
  raise exception 'Submitted OCR was requeued';
 exception when insufficient_privilege then null;
 end;
 payload:='{"page_index":0,"segment_index":0,"status":"READY_TO_CREATE","extracted_data":{"full_name":"ISOLATED TEST","passport_number":"TEST000020"},"raw_result":{"isolated_provider":true}}';
 payload:=payload||jsonb_build_object('batch_id',b.id);
 perform mdac_retry_app_20261027.write_ocr_result_v2('ISOLATED-ocr-retry',b.id,payload);
 perform mdac_retry_app_20261027.write_ocr_result_v2('ISOLATED-ocr-retry',b.id,payload);
 if (select count(*) from mdac_retry_app_20261027.ocr_results where batch_id=b.id)<>1 then raise exception 'OCR duplicate result'; end if;
 perform mdac_retry_app_20261027.finish_ocr_batch('ISOLATED-ocr-retry',b.id,'{"status":"READY_TO_CREATE","total_results":1,"processed_results":1}');
 insert into mdac_retry_app_20261027.test_checks values
 ('ocr_unstarted_recovery_preserves_attempt_and_rotates_token',true),
 ('ocr_old_token_and_requeue_after_provider_start_rejected',true),
 ('ocr_claim_heartbeat_idempotent_result_and_finish',true);
end $$;
commit;
