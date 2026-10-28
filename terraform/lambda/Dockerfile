FROM public.ecr.aws/lambda/python:3.12

RUN dnf install -y git \
    && dnf clean all \
    && pip install --no-cache-dir git-remote-codecommit==1.17

COPY handler.py git_askpass.py ${LAMBDA_TASK_ROOT}/
RUN chmod 755 ${LAMBDA_TASK_ROOT}/git_askpass.py

CMD ["handler.handler"]
